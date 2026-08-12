#!/usr/bin/env bash
# =============================================================================
# agent-loop.sh — the engineering loop that runs inside the Agent Loop workflow.
#
#   implement (loop-builder) → verify (deterministic gate) → feed failures
#   back → repeat until green or out of iterations → independent review
#   (loop-verifier, a *different* agent in a *fresh* session) → one optional
#   fix round → outcome exported to the workflow via $GITHUB_ENV.
#
# Design rule: the agent's claims are never trusted. Only the deterministic
# gate (.github/scripts/detect-and-test.sh) decides whether work is done.
# =============================================================================
set -uo pipefail

: "${TASK:?TASK env var is required}"
BASE_BRANCH="${BASE_BRANCH:-main}"
MAX_ITERATIONS="${MAX_ITERATIONS:-3}"
MODEL="${MODEL:-}"

LOOP_DIR="${RUNNER_TEMP:-/tmp}/agent-loop"
mkdir -p "$LOOP_DIR"

BUILDER_TOOLS="Bash,Read,Edit,Write,Glob,Grep,WebFetch,WebSearch,Skill,TodoWrite"
VERIFIER_TOOLS="Bash,Read,Glob,Grep"
BUILDER_MAX_TURNS="${BUILDER_MAX_TURNS:-50}"
VERIFIER_MAX_TURNS="${VERIFIER_MAX_TURNS:-25}"

MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=(--model "$MODEL")

GREEN=0
ITERATIONS_USED=0
VERDICT="SKIPPED"
SESSION_ID=""
REPORT_PATH="$LOOP_DIR/verifier-report.md"

log() { printf '\n[agent-loop] %s\n' "$*"; }

# ---------------------------------------------------------------- prompts ----
first_prompt() {
  cat <<PROMPT
You are loop-builder, the implementation half of an automated engineering loop running in CI, on branch $(git branch --show-current) (based on ${BASE_BRANCH}).

TASK
----
${TASK}

Work like this:
1. Read LOOP_STATE.md (the repo's memory) and CLAUDE.md before touching anything.
2. Implement the smallest correct change that completes the task, following the project-playbook skill.
3. Add or update tests whenever you change behavior.
4. Run the project checks yourself before declaring anything done: bash .github/scripts/detect-and-test.sh — fix what fails.
5. Commit your intentional changes with clear messages. Never commit dependencies, build artifacts, or secrets.
6. Update LOOP_STATE.md: what you did, decisions you made, anything left for a follow-up.

A deterministic CI gate will re-run all checks after you finish — your work only counts if that gate is green. Finish with a short report: what changed, what you ran, what (if anything) is left.
PROMPT
}

retry_prompt() {
  local iteration="$1" verify_log="$2"
  cat <<PROMPT
The deterministic CI gate FAILED after your previous attempt (this is iteration ${iteration} of ${MAX_ITERATIONS}).

Verification log (tail):
--------------------------------
$(tail -n 120 "$verify_log" 2>/dev/null || echo "(no log captured)")
--------------------------------

Diagnose the failures and fix them for real — do not weaken, skip, or delete tests to force a pass. Re-run bash .github/scripts/detect-and-test.sh yourself until it passes, commit the fixes, and update LOOP_STATE.md.
PROMPT
}

fix_prompt() {
  cat <<PROMPT
The independent reviewer (loop-verifier) examined your work and requested changes:

--------------------------------
$(cat "$1" 2>/dev/null || echo "(report missing)")
--------------------------------

Address every point that is real. If a point is mistaken, do not change code for it — instead record why in LOOP_STATE.md under Decisions. Re-run bash .github/scripts/detect-and-test.sh until green and commit your fixes.
PROMPT
}

verifier_prompt() {
  cat <<PROMPT
You are loop-verifier, the independent reviewer in an automated engineering loop. A different agent (loop-builder) just worked on the current branch. Its task was:

TASK
----
${TASK}

Review the work against base branch ${BASE_BRANCH}:
1. Inspect git log and git diff ${BASE_BRANCH}...HEAD — read every changed file in full.
2. Judge: does the change actually complete the task? Look for correctness bugs, missed edge cases, scope creep, weakened or deleted tests, hardcoded secrets, and debug leftovers.
3. If anything looks suspicious, re-run the gate yourself: bash .github/scripts/detect-and-test.sh
4. Confirm LOOP_STATE.md was updated to reflect this work.

Be adversarial — your job is to find what is wrong, not to be agreeable.

Reply with a concise markdown review report. The very last line of your reply must be exactly one of:
VERDICT: APPROVE
VERDICT: REQUEST_CHANGES
PROMPT
}

# ------------------------------------------------------------ agent calls ----
run_builder() {
  # $1 = prompt, $2 = output json path, $3 = "fresh" | "resume"
  local prompt="$1" out="$2" mode="$3" rc sid
  local resume_args=()
  if [ "$mode" = "resume" ] && [ -n "$SESSION_ID" ]; then
    resume_args=(--resume "$SESSION_ID")
  fi
  claude -p "$prompt" \
    --agent loop-builder \
    --output-format json \
    --permission-mode acceptEdits \
    --allowedTools "$BUILDER_TOOLS" \
    --max-turns "$BUILDER_MAX_TURNS" \
    "${MODEL_ARGS[@]}" \
    "${resume_args[@]}" \
    >"$out" 2>"$out.err"
  rc=$?
  if [ -s "$out" ]; then
    sid=$(jq -r '.session_id // empty' "$out" 2>/dev/null || true)
    [ -n "$sid" ] && SESSION_ID="$sid"
    log "builder report (tail):"
    jq -r '.result // "(no result field)"' "$out" 2>/dev/null | tail -n 40 || true
  else
    log "builder produced no output (rc=$rc); stderr tail:"
    tail -n 20 "$out.err" 2>/dev/null || true
  fi
  return "$rc"
}

run_verifier() {
  # $1 = report output path
  local out="$LOOP_DIR/verifier.json"
  claude -p "$(verifier_prompt)" \
    --agent loop-verifier \
    --output-format json \
    --permission-mode acceptEdits \
    --allowedTools "$VERIFIER_TOOLS" \
    --max-turns "$VERIFIER_MAX_TURNS" \
    "${MODEL_ARGS[@]}" \
    >"$out" 2>"$out.err" || true
  jq -r '.result // "verifier produced no report"' "$out" 2>/dev/null >"$1" \
    || echo "verifier produced no report" >"$1"
  if grep -q '^VERDICT: APPROVE[[:space:]]*$' "$1"; then
    VERDICT="APPROVE"
  elif grep -q '^VERDICT: REQUEST_CHANGES[[:space:]]*$' "$1"; then
    VERDICT="REQUEST_CHANGES"
  else
    VERDICT="NO_VERDICT"
  fi
}

run_verify() {
  # $1 = log path — the deterministic gate; its exit code is the only truth
  bash .github/scripts/detect-and-test.sh 2>&1 | tee "$1"
  return "${PIPESTATUS[0]}"
}

# -------------------------------------------------------------- main loop ----
command -v claude >/dev/null 2>&1 || { echo "::error::claude CLI not on PATH"; exit 1; }
log "Task: $TASK"
log "Max iterations: $MAX_ITERATIONS · builder turns: $BUILDER_MAX_TURNS · verifier turns: $VERIFIER_MAX_TURNS"

for ((i = 1; i <= MAX_ITERATIONS; i++)); do
  ITERATIONS_USED=$i

  echo "::group::Iteration $i/$MAX_ITERATIONS — implement (loop-builder)"
  if [ "$i" -eq 1 ]; then
    run_builder "$(first_prompt)" "$LOOP_DIR/builder-$i.json" fresh \
      || log "builder exited non-zero; running the gate anyway"
  else
    run_builder "$(retry_prompt "$i" "$LOOP_DIR/verify-$((i - 1)).log")" "$LOOP_DIR/builder-$i.json" resume \
      || log "builder exited non-zero; running the gate anyway"
  fi
  echo "::endgroup::"

  echo "::group::Iteration $i/$MAX_ITERATIONS — deterministic verify"
  if run_verify "$LOOP_DIR/verify-$i.log"; then
    GREEN=1
    echo "::endgroup::"
    log "Gate GREEN after iteration $i"
    break
  fi
  echo "::endgroup::"
  log "Gate RED after iteration $i"
done

# ---------------------------------------------- independent review + fixes ----
if [ "$GREEN" -eq 1 ]; then
  echo "::group::Independent review (loop-verifier, fresh session)"
  run_verifier "$REPORT_PATH"
  echo "::endgroup::"
  log "Verifier verdict: $VERDICT"

  if [ "$VERDICT" = "REQUEST_CHANGES" ] && [ "$ITERATIONS_USED" -lt "$MAX_ITERATIONS" ]; then
    ITERATIONS_USED=$((ITERATIONS_USED + 1))
    echo "::group::Fix round from review (loop-builder)"
    run_builder "$(fix_prompt "$REPORT_PATH")" "$LOOP_DIR/builder-fix.json" resume || true
    echo "::endgroup::"

    echo "::group::Re-verify after fix round"
    if run_verify "$LOOP_DIR/verify-fix.log"; then GREEN=1; else GREEN=0; fi
    echo "::endgroup::"

    if [ "$GREEN" -eq 1 ]; then
      echo "::group::Re-review after fix round (loop-verifier)"
      run_verifier "$REPORT_PATH"
      echo "::endgroup::"
      log "Verifier verdict after fix round: $VERDICT"
    fi
  fi
else
  log "Skipping independent review — the gate never went green"
  echo "Review skipped: the deterministic gate never passed within ${MAX_ITERATIONS} iteration(s)." >"$REPORT_PATH"
fi

# ------------------------------------------------------------------ export ----
TOTAL_COST_USD=$(cat "$LOOP_DIR"/builder-*.json "$LOOP_DIR"/verifier.json 2>/dev/null \
  | jq -rs '[.[] | .total_cost_usd? // 0] | add // 0 | . * 100 | round / 100' 2>/dev/null)
[ -n "$TOTAL_COST_USD" ] || TOTAL_COST_USD="n/a"

{
  echo "GREEN=$GREEN"
  echo "ITERATIONS_USED=$ITERATIONS_USED"
  echo "VERDICT=$VERDICT"
  echo "VERIFIER_REPORT=$REPORT_PATH"
  echo "TOTAL_COST_USD=${TOTAL_COST_USD:-n/a}"
} >>"${GITHUB_ENV:-$LOOP_DIR/outcome.env}"

log "Loop finished: GREEN=$GREEN · iterations=$ITERATIONS_USED · verdict=$VERDICT · est. cost=\$${TOTAL_COST_USD:-n/a}"
# The workflow decides pass/fail after pushing the branch and opening the PR.
exit 0
