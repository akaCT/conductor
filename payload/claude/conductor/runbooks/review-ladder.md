# Review ladder

Choose the tier by what is at stake, name it in the dispatch, and name each reviewer's model and effort.

| Tier | When | Panel |
|---|---|---|
| 1 | Routine work whose checks pass | 1 critic that owns every relevant lens |
| 2 | Work whose number, design or gate people will rely on | 2 critics with distinct lenses |
| 3 | A decision the user acts on | Tier 2 plus the judge, once per decision |
| 4 | Anything irreversible, or a build plan | Everything in tier 3 plus a critic run on `opus`; the judge and that critic each answer the other's findings with evidence, and you adjudicate |

## 2 rules from tier 2 up
1. At least 1 reviewer uses another model than the author's. Work you wrote gets `sonnet` critics or the judge. Work a `sonnet` builder wrote gets the critic agent run with model `opus`, or the judge. Turning up effort on the author's own model does not give a second view; the same blind spot comes back with more confidence.
2. At least 1 reviewer rebuilds the answer on its own, working from the spec and the raw data, and does not re-run the author's scripts.

## Contracts for critics
- Give each critic 1 lens and say "every section, not only the first".
- Put no severity or confidence filter in a critic contract. A critic told to hold back withholds real defects. You filter afterward.
- Ask for evidence anchors: a path, a line, a command and its output.
- Data-fidelity lens: add it as a third seat only when the work transforms data.

## Adjudicating
- Reviewer agreement is not proof. Check each finding against the artifact.
- 1 verified serious defect blocks the work, whatever the other reviewers said.
- An unresolved consequential claim stays open until evidence or the user settles it.
- Run deterministic checks before any model review, and do not repeat passing checks without a change.

## The judge
Gates: an irreversible tie-break, a blind spot, a taste plateau, the user asks. Hand it the artifact and the exact question, not your thread. It reads only the paths the contract names. It gets no security calls.
- Rung 1 (`fable`) is the most independent seat, where the account has it.
- Rung 3 (`sonnet`) runs in a fresh context that sees only the artifact and works the answer out again from the spec and raw data. It is a weaker view than a different model family; say so in the verdict.
- Rung 2, a judge from another lab, comes in a later release.
- Work an `opus` seat wrote is never judged by another `opus` seat.
- If a judge dispatch fails, tell the user and run that review on rung 3.
- Never use `max` effort for the judge.

## Improvement rounds
If an improvement skill is installed and the user asked for rounds, run them. If it is not installed, skip the improvement step and carry on.

A Workflow template for a tier 2 panel is at `conductor/templates/review-ladder.workflow.js`. It needs the Workflow tool; the ladder works the same with plain Agent calls.
