# Loop Engineering Pipeline

## TL;DR

You give it a task. An AI agent builds it, a script proves it works, a second
agent reviews it, and you get a PR. **Nothing merges without you.**

1. Copy this repo's files into your project.
2. Add the `ANTHROPIC_API_KEY` repo secret.
3. Settings → Actions → General → enable **"Allow GitHub Actions to create and
   approve pull requests"**.
4. Actions tab → **Agent Loop** → *Run workflow* → type your task → review the
   PR that comes back.

That's it. Everything below is detail.

## What it is

A GitHub Actions implementation of *loop engineering*: an automated
implement → verify → review cycle where the agent's word is never trusted —
a deterministic script (`.github/scripts/detect-and-test.sh`) re-runs
install + lint + typecheck + tests + build after every agent pass, and its
exit code is the only thing that counts as "done."

```
task in
  │
  ▼
builder agent implements, tests, commits     ─┐
deterministic gate re-runs ALL checks         │ repeats until green
red? failure log goes back to the builder    ─┘ (≤ max_iterations)
  │ green
  ▼
verifier agent (fresh session) reviews the diff
  │ REQUEST_CHANGES? → one fix round → re-verify
  ▼
run logged in LOOP_STATE.md · branch pushed · PR opened
(draft + `loop:red` label if the gate never passed)
  │
  ▼
you review and merge — the loop never merges its own work
```

## The pieces

| File | Role |
|---|---|
| `.github/workflows/agent-loop.yml` | The parameterized loop — run it from the Actions tab |
| `.github/workflows/agent-discovery.yml` | Scheduled scout: files `agent-loop` issues with ready-to-paste tasks (Mondays 06:00 UTC) |
| `.github/scripts/agent-loop.sh` | The loop itself: implement → gate → review |
| `.github/scripts/detect-and-test.sh` | The gate. Auto-detects the stack (Node, Python, etc.) and runs every check deterministically |
| `.claude/agents/loop-builder.md` | Sub-agent that implements the task |
| `.claude/agents/loop-verifier.md` | Sub-agent that reviews the diff cold and returns APPROVE / REQUEST_CHANGES |
| `.claude/agents/loop-scout.md` | Sub-agent that discovers and triages work |
| `.claude/skills/project-playbook/SKILL.md` | Project knowledge — commands, conventions, definition of done. Agents read this instead of guessing |
| `LOOP_STATE.md` | Memory: what's done, what's next, past decisions. Read first, written last, appended by every run |
| `CLAUDE.md` | The loop contract any agent in this repo must follow |
| `LOOP_PIPELINE.md` | The full guide (setup, connectors, safety, cost) |

## Running it

**On demand** — Actions → *Agent Loop* → *Run workflow*:

| Input | What it does | Default |
|---|---|---|
| `task` | What to build/fix/change. More precise = fewer iterations | required |
| `base_branch` | Branch to start from and target the PR at | `main` |
| `max_iterations` | Implement → verify rounds before giving up | `3` |
| `verify_command` | Override the auto-detected gate (e.g. `npm run ci`) | auto-detect |
| `model` | Model override for the agents | provider default |

**On a schedule** — *Agent Discovery & Triage* runs Mondays 06:00 UTC. The
scout files at most 5 evidence-backed issues labeled `agent-loop`, each ending
in a "Task for the loop" paragraph you paste straight into the `task` input.
A human stays between discovery and execution by design.

Every run is isolated: its own ephemeral runner, its own
`agent/<slug>-<run_id>` branch. Two runs never touch each other.

## Using this repo as a template

Copy everything (or use GitHub's "Use this template" if enabled) into your
project, then:

1. Add the `ANTHROPIC_API_KEY` secret and enable Actions PR creation (TL;DR
   steps 2–3).
2. If your default branch isn't `main`, pass `base_branch` when running or
   change the default in `agent-loop.yml`.
3. If your project already has a `CLAUDE.md`, append this repo's loop-contract
   section to it instead of overwriting.
4. Teach it your project: either fill in the TODOs in
   `.claude/skills/project-playbook/SKILL.md` by hand, or make that the first
   loop run — task: *"Inspect this repository and fill in every TODO in
   .claude/skills/project-playbook/SKILL.md with accurate, verified content."*

Optional: commit a `.mcp.json` at repo root to give the agents MCP connectors
(Linear, etc.) — see `LOOP_PIPELINE.md` for the wiring.

## Safety & cost

- Agents run with an explicit allowed-tools list on ephemeral runners, on
  their own branches. They never push to the base branch and never merge.
- Results always arrive as PRs — drafts labeled `loop:red` when the gate
  failed, `loop:green` when it passed. The workflow run itself fails if the
  gate never went green.
- Protect your base branch (require PR + review) so the only path to it is a
  human merge.
- Cost is bounded by `max_iterations` × the per-agent turn caps set in
  `.github/scripts/agent-loop.sh`; each PR and job summary shows the
  estimated API cost of the run.
