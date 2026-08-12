# The engineering loop pipeline

A GitHub Actions implementation of loop engineering: you hand it parameters, an
agent does the work, a deterministic gate makes sure the work is actually done,
tested, and checked — and an independent second agent reviews it before a human
ever sees the PR.

## The six primitives, mapped to files

| Primitive | Job in the loop | Where it lives here |
|---|---|---|
| **Automations** | discovery + triage on a schedule | `.github/workflows/agent-discovery.yml` (cron + manual), `.github/workflows/agent-loop.yml` (parameterized run-until-done) |
| **Worktrees** | isolate parallel work | every loop run gets its own ephemeral runner **and** its own `agent/<slug>-<run_id>` branch — two runs never touch each other; locally, use `git worktree` for the same effect |
| **Skills** | codify project knowledge | `.claude/skills/project-playbook/SKILL.md` — commands, conventions, definition of done; agents read it instead of guessing |
| **Plugins / connectors** | plug into your tools | commit a `.mcp.json` at repo root and the agents pick it up in CI (see "Connectors" below) |
| **Sub-agents** | one has the idea, another checks it | `.claude/agents/loop-builder.md` implements; `.claude/agents/loop-verifier.md` reviews cold in a fresh session; `.claude/agents/loop-scout.md` triages |
| **State / memory** | remember what's done and what's next | `LOOP_STATE.md` — read first, written last, appended by every run. The agent forgets, the repo doesn't. |

## How a run works

```
you (or the scout) supply parameters:
task · base_branch · max_iterations · verify_command · model
        │
        ▼
┌─ agent-loop.yml ─────────────────────────────────────────────┐
│  1. checkout base, create isolated branch agent/<slug>-<id>  │
│  2. loop (≤ max_iterations):                                 │
│       loop-builder implements, tests, commits                │
│       deterministic gate re-runs ALL checks                  │
│       red? → failure log is fed back to the builder          │
│  3. green → loop-verifier (fresh session) reviews the diff   │
│       REQUEST_CHANGES? → one fix round → re-verify, re-review│
│  4. run recorded in LOOP_STATE.md (memory)                   │
│  5. branch pushed, PR opened (draft if red/rejected),        │
│     labels loop:green / loop:red, review report in PR body   │
│  6. workflow fails if the gate never went green              │
└──────────────────────────────────────────────────────────────┘
        │
        ▼
you review and merge the PR — the loop never merges its own work
```

The trust rule that holds the loop together: **the agent's word is never the
gate.** `.github/scripts/detect-and-test.sh` re-runs install + lint + typecheck
+ tests + build deterministically after every builder pass, and its exit code is
the only thing that counts as "done, tested, and checked."

## Setup (one time, ~5 minutes)

1. **Copy the files** in this package to your repo root (paths are already
   repo-relative). If you already have a `CLAUDE.md`, append the section from
   the packaged one instead of overwriting.
2. **Add the secret**: repo → Settings → Secrets and variables → Actions → new
   repository secret `ANTHROPIC_API_KEY` (from console.anthropic.com).
3. **Allow PR creation**: Settings → Actions → General → Workflow permissions →
   check **"Allow GitHub Actions to create and approve pull requests"** (and
   keep "Read and write permissions" or rely on the workflow's `permissions:`
   block).
4. **Teach it your project** — either edit
   `.claude/skills/project-playbook/SKILL.md` by hand, or make it the first loop
   run: Actions → **Agent Loop** → Run workflow → task:
   *"Inspect this repository and fill in every TODO in
   .claude/skills/project-playbook/SKILL.md with accurate, verified content."*
5. If your default branch isn't `main`, pass `base_branch` when running (or
   change the input default in `agent-loop.yml`).

## Running it

**On demand**: Actions tab → *Agent Loop* → *Run workflow* → fill the parameters:

- `task` — what to build/fix/change (the more precise, the fewer iterations)
- `base_branch` — default `main`
- `max_iterations` — implement→verify rounds before giving up (default 3)
- `verify_command` — override the auto-detected gate (e.g. `npm run ci`)
- `model` — optional model override

**On a schedule**: *Agent Discovery & Triage* runs Mondays 06:00 UTC (edit the
cron). The scout files at most 5 evidence-backed issues labeled `agent-loop`,
each ending in a "Task for the loop" paragraph you can paste straight into the
Agent Loop's `task` input. Human in the middle by design; if you want full
autonomy later, let the scout dispatch runs itself with
`gh workflow run agent-loop.yml -f task="..."` (add `actions: write` permission
and the command to its prompt — deliberately not enabled by default).

## Connectors (MCP)

Commit a `.mcp.json` at repo root and every agent in CI can use those tools —
for example, Linear as the loop's memory/board instead of (or alongside)
`LOOP_STATE.md`:

```json
{
  "mcpServers": {
    "linear": {
      "type": "http",
      "url": "https://mcp.linear.app/mcp",
      "headers": { "Authorization": "Bearer ${LINEAR_API_KEY}" }
    }
  }
}
```

Then add `LINEAR_API_KEY: ${{ secrets.LINEAR_API_KEY }}` to the workflow `env:`
blocks and extend `--allowedTools` with the MCP tools (e.g.
`mcp__linear__create_issue`). Check your provider's docs for the exact MCP URL.

## Safety & cost

- Agents run with `--permission-mode acceptEdits` and an explicit
  `--allowedTools` list, on an ephemeral runner, on their own branch. Tighten
  further with scoped rules like `Bash(npm *)` if you want.
- The loop never merges: results always arrive as PRs (drafts when red or
  rejected), and the workflow run itself fails when the gate never passed.
- Protect your base branch (require PR + review) so the only path to `main` is
  a human merge.
- Cost is bounded by `max_iterations` × `--max-turns` (50 builder / 25
  verifier, set in `.github/scripts/agent-loop.sh`). Each PR and job summary
  shows the estimated API cost of the run.

## Files in this package

```
.github/workflows/agent-loop.yml        the parameterized engineering loop
.github/workflows/agent-discovery.yml   scheduled discovery & triage
.github/scripts/agent-loop.sh           the loop itself (implement→verify→review)
.github/scripts/detect-and-test.sh      deterministic gate (auto-detects stack)
.claude/agents/loop-builder.md          sub-agent: implements
.claude/agents/loop-verifier.md         sub-agent: reviews, verdict APPROVE/REQUEST_CHANGES
.claude/agents/loop-scout.md            sub-agent: discovers & triages
.claude/skills/project-playbook/SKILL.md  project knowledge (fill the TODOs)
LOOP_STATE.md                           the memory — read first, written last
CLAUDE.md                               the loop contract for any agent in this repo
LOOP_PIPELINE.md                        this guide
```
