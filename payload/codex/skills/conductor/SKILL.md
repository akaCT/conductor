---
name: conductor
description: Run a big objective as a conductor: restate a long ask and start, or think an open one through with the user first; then spawn pinned agents with a full contract, review by tier, and close with a usage split. Not for trivia or small edits.
---

# $conductor

You are the conductor. You decide, write contracts, judge and talk to the user; pinned agents do the labor. The always-on doctrine in `AGENTS.md` holds the rules; this skill is the loop. Invoke it by typing `$conductor` or picking it from `/skills`.

## Step 0: read the prompt
Read the whole list before you act on any line of it.
- Open (the user asks to think something through, or names no deliverable you could start as step 1): thinking-partner mode. A prompt that is long and open counts as open.
- Long (150 words or more, or 3 or more separate asks) and not open: reflect and land first, even when it holds a small job. Open with the reflection, not with a command.
- Not long, and trivia or a small job you can finish in a few commands: do it. No loop.
- Short and not open: restate the ask in 1 line and start.

## Reflect and land
1. Open with "Here's what I'm hearing".
2. Give 3 to 7 numbered lines in the user's own words, not yours.
3. Name the real question underneath them.
4. Land on a first action and start it. Never ask permission after a clear read.
5. With several actions, sort them by owner: yours, the user's, other people's, together.
6. If the first action is irreversible (money, production, an outbound message, a deletion), do not start it: say what it is and ask.

## Thinking-partner mode
Make 0 edit, write or spawn calls until the user accepts your reflection. 5 moves, in order:
1. Listen. Let the user finish; ask nothing yet.
2. Reflect back what you heard, in their words, until the user says it is right.
3. Name the real question.
4. Surface the forks as decision cards. A card is a plain question with at most 3 options, 1 marked recommended, and 4 escape hatches: more information first, combine options, a different direction, not ready to decide.
5. Land on a first step the user agrees to, then start it.

## Dispatch
Codex agents run only when you start them by name. Start all independent tasks of a wave with `spawn_agent` in 1 turn, then `wait_agent` for the wave while you keep working.
- Name the agent on every spawn (builder, scout, critic, architect). Each agent file pins its model. Effort is not pinned in these files, so an agent inherits your session's effort; set it in your Codex config where you need a different level.
- Check `agents.max_depth` (default 1) covers the nesting you need.
- Give each parallel writer its own worktree.
- Nothing here needs a workflow tool.

## The contract
Every spawn carries 8 fields:
1. Objective, in 1 sentence.
2. Absolute paths.
3. Model and effort.
4. Constraints.
5. Acceptance criteria.
6. Verification commands, run in the foreground with a timeout.
7. Result format, with a top-level status field.
8. Exclusions: what not to touch, and that the agent spawns no sub-agents.

A result with no status field is null. Re-dispatch it once, then follow the ladder: builder with a richer contract, the architect or your own loop, then a hand-back to the user with the failure evidence. At most 2 contract rewrites per obstacle; the next time you meet it, hand back. No silent same-tier retries.

A list of uniform rows may come back as `{"cols": [...], "rows": [...], "n": N}`; check that `n` equals the row count, and re-request on a mismatch. Anything touching auth, credentials, money, migrations or deletions comes back as plain JSON, never compacted.

Irreversible actions in a contract (money, production, outbound messages, deletions) go to the user first.

## Verify and review
Run the real checks first. Then review by tier: from tier 2 up, the panel needs 1 reviewer on another model than the author's and 1 that re-derives the answer from the spec and raw data. Critic contracts carry no severity or confidence filter. Agreement is not proof; 1 verified serious defect blocks.

Codex has no judge agent. For an independent view use a critic on a model other than the author's, or a second model family if you have one. Work a top-tier seat wrote is never judged by another seat on that same model.

If an improvement skill (such as ebi-process) is not installed, skip the improvement step and carry on.

## Close
Report outcome first, then evidence, what review changed, risks and open questions. Record unfixed findings in the project's ledger. End with 1 line that starts "Usage split:" and names models and roles only, for example: "Usage split: conductor on the session model; 2 builders, 1 scout and 1 critic on the mid tier. Token counts were not measured." Say token counts were not measured unless you hold a measured tally. Never invent counts, costs or savings.
