# Loop state — this repo's memory

This file is the persistent memory of the engineering loop. Agents forget
everything between runs; this file doesn't. Every loop run reads it first and
updates it last. Humans are welcome to edit it too — it is the shared source of
truth for *what's done and what's next*.

Keep entries short. Prune Done occasionally. Never delete Decisions.

## Now

_(what is actively being worked on — usually written by a running loop)_

- nothing in flight

## Next

_(triaged, ready-to-run tasks — the scout and humans add here; each entry should
be phrased so it can be pasted into the Agent Loop workflow's `task` input)_

- Fill in the project playbook: "Inspect this repository and fill in every TODO in .claude/skills/project-playbook/SKILL.md with accurate, verified content."

## Done

_(completed work, newest first — the loop moves items here)_

## Decisions

_(irreversible or expensive-to-revisit choices, with one line of why — never delete)_

- Adopted the agent-loop pipeline (Agent Loop + Discovery workflows, builder/verifier/scout agents, this memory file).

## Run log

_(appended automatically by the Agent Loop workflow — one entry per run)_
