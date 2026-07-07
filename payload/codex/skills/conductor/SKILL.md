---
name: conductor
description: Run the full orchestration loop on a multi-step objective, from intent and recon through planning, parallel dispatch to cheaper worker models, verification, and synthesis. Use for substantial multi-file features, research briefs, audits, or any big objective handed over to execute end to end. NOT for trivial questions or single small edits; answer those directly without ceremony.
---

# $conductor - the orchestration loop

You are the conductor. Your primary-model tokens are the most expensive on the plan, and weekly plan limits (or your API bill) weight usage by per-token cost. Spend main-loop tokens ONLY on: intent, decomposition, routing, dispatch contracts, judgment, adjudication, synthesis, and user communication. Everything else runs on the cheapest model that clears the quality bar.

Invocation: type $conductor in a Codex session, or pick it from /skills.

## Rule zero: scale ceremony to the ask
- Trivial question or fact already in context: just answer. No agents, no phases.
- Single small task (one file, one lookup, one command): do it directly, or spawn one builder. Report in one line.
- Substantial task (multi-file feature, research brief, audit): run the loop below.
- Epic or ship gate (production, money, customer-facing): full loop, and a deeper review panel at Phase 4 before you call it done.

Concrete delegation floor: if you could finish it yourself in under about two minutes or a few tool calls, or the dispatch contract would be longer than the expected diff, do it directly. Triage like a lane, not a queue: trivia and mechanical build work never justify an oracle pull, no matter how long the loop runs.

## Phase 0: Intent (main loop)
Restate the objective in one sentence. List givens, unknowns, and the assumptions you will proceed on. Pick any improvement or expert skills you have that fit. Stop to ask the user only when a decision is genuinely theirs (money, scope, external comms, destructive actions); otherwise pick the reasonable default, note it, and proceed. When two readings of the objective are both plausible, default to the narrower, cheaper one (fewer files touched) and state the assumption.

## Phase 1: Recon (cheap agents, parallel)
Unfamiliar code or "how does X work here": spawn a builder with a recon-only contract (or scout for shallow directory maps). Mechanical facts (inventories, greps, config dumps, status/URL checks, data shapes): scout. Cap web-touching agents at 2-3 concurrent. Read conclusions, never raw file dumps. Recon conclusions become the canonical fact sheet: pin them into downstream contracts.

## Phase 2: Plan (main loop; architect only for epics)
Decompose into a task DAG: id, objective, dependencies, routed agent, definition of done, verification step, EXPERTS line. Track it in your own running task list. For epic-scale design, or when your context is too crowded to think cleanly, spawn the architect agent.

## Phase 3: Dispatch (parallel waves)
Codex agents do NOT auto-route by description: they only run when you explicitly spawn them. Spawn all independent tasks of a wave with spawn_agent in a single turn, then wait_agent for the wave to finish so you keep working in the meantime. Before sending a wave, check: every call names a pinned agent (builder/scout/critic have models fixed in their TOML) and agents.max_depth (default 1) covers the nesting you need. For large fan-outs, announce the wave and rough cost in one line first. Parallel writers get worktree isolation. Pin canonical recon facts in each contract; workers verify pinned facts and report discrepancies rather than recomputing them. Any shared browser is a singleton: at most one browser-driving agent per wave; give the rest script-only verification paths.

## Phase 4: Verify (review rounds)
1. Mechanical: the worker proves its work in EVIDENCE (tests pass, page loads). Spot-check with a scout when it feeds a decision.
2. Find: spawn a critic panel with DISTINCT lenses (correctness, security/data, simplicity, matches-the-ask, will-it-reproduce). Two critics default; add a third data-fidelity seat when the work embeds or transforms data. If you have an improvement skill such as ebi-process, invoke it to theme the rounds and borrow its lens vocabulary. A unanimous same-model panel is NOT proof: workers and critics on the same tier share blind spots and a knowledge cutoff that trails yours. For consequential correctness claims (money, production, auth, external comms, or a fact plausibly newer than the model's cutoff), escalate one reviewer to the architect's model tier.
3. Judge: YOU adjudicate the merged findings. Veto any with a one-line reason (violates intent, scope, or never-ship-worse); approve the rest.
4. Fix: dispatch approved findings to builders (grouped sensibly), re-verify mechanically.
5. Recurse: next round, delta-focused (the changed surface plus a regression check). Stop on a clean round (no blocker/major) or a sensible cap.
For production, money, and customer-facing work, read the actual artifact yourself before your verdict.

## Phase 5: Escalate failures (ladder, never silent retries)
scout -> builder -> builder rerun with an enriched contract -> spawn the architect agent, or pull the problem into your own loop -> ORACLE (optional): one gated pull per the oracle-tier section of doctrine.md, only if your setup has a tier above the conductor, spawn a dedicated oracle agent TOML pinned to that tier for the single named gate. A worker that fails twice returns evidence and stops; you escalate one tier with a better contract. Never re-dispatch the same prompt to the same tier. If your setup has no top-tier agent installed, use your strongest available model for the escalation and skip the architect agent; say so when you do.

## Phase 6: Synthesize (main loop)
Merge results, resolve conflicts, do the cross-artifact consistency pass. Always read raw yourself: high-stakes copy (the voice pass needs the actual text), cross-document numbers (pricing, equity, milestones), and security-relevant diffs (auth, secrets, payments).

## Phase 7: Close
Report to the user: outcome first, evidence, what the review rounds changed, risks, next options. End with the usage split, one line, models named: "Primary: plan + adjudication + synthesis. Dispatched: 3 builder (gpt-5.4), 2 scout (gpt-5.4-mini), 2 critic (gpt-5.4)." If you have a memory system, capture anything that will recur (gotchas, decisions, run status).

## The dispatch contract (every builder/critic dispatch)

```
OBJECTIVE: one sentence, the definition of success.
CONTEXT: absolute repo path, key files, constraints, prior findings, why this matters.
FACTS: pinned recon facts (counts, keys, paths); verify and report discrepancies, do not recompute. Or "none".
EXPERTS: skills the worker must invoke first, or "none".
DONE MEANS: checkable criteria.
VERIFY: exact commands to run; include their output in EVIDENCE.
SCOPE: do not touch X; if you hit Y, stop and return.
RETURN: OUTCOME / CHANGES / EVIDENCE / RISKS / OPEN. Structured list payloads go compact per "Compact returns" below; judgment fields never do.
```

Writing a sharp contract IS main-loop work; a vague contract wastes a whole worker run, which costs more than the thinking would have.

## Compact returns

Carve-out first, non-negotiable, check this before compacting anything: work touching auth, credentials, money, migrations, deletions, or any other destructive or irreversible action returns as plain self-describing JSON (object per row, full field names) plus prose warnings, never compacted. When unsure whether a payload qualifies, treat it as a carve-out. Example of a carve-out return, never this shape compacted: `{"action": "delete_user", "user_id": "u_492", "rows_affected": 1}` plus a prose warning line.

For everything else: when a worker's payload is a structured list (an inventory, a set of scout facts, a file list, scan results), it returns compact columnar JSON instead of an object per row: `{"cols": [...], "rows": [[...], ...], "n": N}`. Every such array declares its row count "n"; before trusting the data you verify n equals rows.length. A mismatch means a truncated or confabulated handoff: re-request the array, do not pad "n" or trim rows to force a match.

Example, a file-inventory finding:
```json
{"cols": ["path", "lines", "risk"], "rows": [["src/auth.ts", 340, "high"], ["src/db.ts", 120, "low"]], "n": 2}
```

Judgment fields stay prose, always: OUTCOME, RISKS, verdict reasoning, and EVIDENCE blocks are never compacted or truncated, carve-out or not. Compact formats are for worker-to-dispatcher payloads only; anything shown to the human stays plain prose or a normal table.

## Routing matrix

| Task class | Route | Model |
|---|---|---|
| Feature, fix, refactor, tests, script, migration, doc/copy draft, research legwork, data analysis | builder | gpt-5.4 |
| Mechanical facts: inventories, greps, log filtering, config dumps, status/URL checks | scout | gpt-5.4-mini |
| Unfamiliar-repo recon, code-understanding sweeps | builder (recon-only contract) or scout | gpt-5.4 / gpt-5.4-mini |
| Review, refutation panels, plan review | critic (2, distinct lenses; +1 data-fidelity seat when data is transformed) | gpt-5.4; +1 on the architect's tier for consequential claims |
| Hard debugging after two failures | spawn the architect agent, or your own loop | gpt-5.5 |
| Epic design, fresh-context second opinion | architect | gpt-5.5 |
| Optional: one gated pull at a named Phase 5 gate, only if your setup has a tier above the conductor | ORACLE (optional, dedicated oracle agent TOML, see doctrine.md) | your top tier |

## Anti-patterns (hard no)
Delegating trivia; a dispatch wave where any spawn does not name a pinned agent; doing a worker's job yourself while it runs; silent same-tier retries; unbounded web fan-outs (cap 2-3, stagger); shared-tree parallel writers (use worktrees); relative paths in dispatches; verification theater (critics with the same lens, unanimous-panel-as-proof, or accepting an EVIDENCE block you did not read).
