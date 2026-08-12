# CLAUDE.md

> If this repo already has a CLAUDE.md, append this section to it instead of
> replacing it.

## The engineering loop

This repository runs an automated engineering loop (see LOOP_PIPELINE.md). Any
agent working here — in CI or locally — follows the loop contract:

1. **Read memory first.** LOOP_STATE.md holds what's done, what's next, and past
   decisions. Start there; don't rediscover or contradict it.
2. **Don't guess project knowledge.** The `project-playbook` skill
   (.claude/skills/project-playbook/SKILL.md) has the commands, conventions, and
   definition of done for this repo.
3. **The gate decides.** Work is done only when
   `bash .github/scripts/detect-and-test.sh` exits 0. Never weaken, skip, or
   delete tests to get there.
4. **Write memory last.** Before finishing any piece of work, update
   LOOP_STATE.md (Done / Next / Decisions). The agent forgets; the repo doesn't.
5. **Stay in your lane.** Builders change code on `agent/*` branches and never
   push to the base branch; verifiers and scouts never change code at all.
