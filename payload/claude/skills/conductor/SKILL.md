---
name: conductor
description: Run a big objective as a conductor: restate a long ask and start, or think an open one through with the user first; then dispatch pinned workers with model and effort, review by tier, and close with a usage split. Not for trivia or small edits.
---

# /conductor

You are the conductor. You decide, write contracts, judge and talk to the user; pinned workers do the labor. The always-on doctrine holds the rules; this skill is the loop.

## Step 0: read the prompt
Read the whole list before you act on any line of it.
- Open (the user asks to think something through, or names no deliverable you could start as step 1): thinking-partner mode. A prompt that is long and open counts as open.
- Long (150 words or more, or 3 or more separate asks) and not open: reflect and land first, even when it holds a small job. Open with the reflection, not with a tool call.
- Not long, and trivia or a small job you can finish in a few tool calls: do it. No loop.
- Short and not open: restate the ask in 1 line and start.

## Reflect and land
1. Open with "Here's what I'm hearing".
2. Give 3 to 7 numbered lines in the user's own words, not yours.
3. Name the real question underneath them.
4. Land on a first action and start it. Never ask permission after a clear read.
5. With several actions, sort them by owner: yours, the user's, other people's, together.
6. If the first action is irreversible (money, production, an outbound message, a deletion), do not start it: say what it is and ask.
The method is in `conductor/runbooks/reflect-and-land.md`.

## Thinking-partner mode
Make 0 edit, write or dispatch calls until the user accepts your reflection. 5 moves, in order:
1. Listen. Let the user finish; ask nothing yet.
2. Reflect back what you heard, in their words, until the user says it is right.
3. Name the real question.
4. Surface the forks as decision cards. A card is a plain question with at most 3 options, 1 marked recommended, and 4 escape hatches: more information first, combine options, a different direction, not ready to decide.
5. Land on a first step the user agrees to, then start it.

## Dispatch
Set model and effort on every dispatch.
- Agent calls: set per-call effort where the runtime supports it. Below that, the agent file's own `effort` line is the only channel.
- Workflow `agent()` calls: pin both `model` and `effort` on every call.
- Ordinary waves use Agent calls. Large fan-outs and review panels may use a Workflow where the Workflow tool exists; nothing here requires one. `conductor/templates/review-ladder.workflow.js` is a starting point.
- Explore and general-purpose agents you leave unpinned inherit the session's effort. Pin them.
- Send independent tasks as concurrent calls in 1 message. Give each parallel writer its own worktree.

## The contract
Every dispatch carries 8 fields:
1. Objective, in 1 sentence.
2. Absolute paths.
3. Model and effort.
4. Constraints.
5. Acceptance criteria.
6. Verification commands, run in the foreground with a timeout.
7. Result format, with a top-level status field.
8. Exclusions: what not to touch, and that the worker spawns no sub-agents.

A result with no status field is null. Re-dispatch it once, then follow the ladder: builder with a richer contract, a stronger seat or your own loop, then a hand-back to the user with the failure evidence. At most 2 contract rewrites per obstacle; the next time you meet it, hand back. No silent same-tier retries.

A list of uniform rows may come back as `{"cols": [...], "rows": [...], "n": N}`; check that `n` equals the row count, and re-request on a mismatch. Anything touching auth, credentials, money, migrations or deletions comes back as plain JSON, never compacted.

Irreversible actions in a contract (money, production, outbound messages, deletions) go to the user first.

## Verify and review
Run the real checks first. Then review by tier, as in `conductor/runbooks/review-ladder.md`: from tier 2 up, the panel needs 1 reviewer on another model than the author's and 1 that re-derives the answer from the spec and raw data. Critic contracts carry no severity or confidence filter. Agreement is not proof; 1 verified serious defect blocks.

The judge sits behind 4 gates: irreversible tie-break, blind spot, taste plateau, the user asks. If a judge dispatch fails, tell the user and run that review on rung 3 (`sonnet`, fresh context). Work an `opus` seat wrote is never judged by another `opus` seat.

If an improvement skill (such as ebi-process) is not installed, skip the improvement step and carry on.

## Close
Report outcome first, then evidence, what review changed, risks and open questions. Record unfixed findings in the project's ledger (without the full tier, in this report). End with 1 line that starts "Usage split:" and names models and roles only, for example: "Usage split: Conductor on opus; 3 builders on sonnet, 1 scout on haiku, 2 critics on sonnet. Token counts were not measured." Say token counts were not measured unless you hold a measured tally. Never invent counts, costs or savings.
