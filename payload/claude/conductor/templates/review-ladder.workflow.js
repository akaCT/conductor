// Review ladder, tier 2 panel: a Workflow script template written for Conductor.
//
// It needs the Workflow tool. The /conductor skill works without it: send the same
// 2 critic prompts as plain Agent calls, each with model and effort set.
//
// Fill in ARTIFACT, SPEC and AUTHOR_MODEL, then pass the script to the Workflow tool.
// Every agent() call below sets both model and effort. Keep it that way when you edit.

const ARTIFACT = "/absolute/path/to/the/artifact";
const SPEC = "/absolute/path/to/the/spec";
const AUTHOR_MODEL = "sonnet"; // the model that wrote the artifact

// Tier 2 needs a reviewer on a model other than the author's.
const OTHER_MODEL = AUTHOR_MODEL === "opus" ? "sonnet" : "opus";

const RESULT_FORMAT =
  "Return JSON with a top-level status field (PASS, FAIL or UNVERIFIED), " +
  "a findings list (each with severity, an evidence anchor and the line or command), " +
  "and a 1-line reason for the status. Report every defect you find.";

const FIRST_LENS =
  "Lens: correctness. Re-derive the result from the spec at " + SPEC +
  " and the raw data it names. Do not re-run the author's scripts. Artifact: " + ARTIFACT + ". " +
  "Cover every section, not only the first. " + RESULT_FORMAT;

const SECOND_LENS =
  "Lens: does it match the ask, and what breaks at the edges. Read the spec at " + SPEC +
  " and the artifact at " + ARTIFACT + ". Cover every section, not only the first. " +
  "Do not spawn sub-agents. " + RESULT_FORMAT;

const [first, second] = await Promise.all([
  agent(FIRST_LENS, { agentType: "critic", model: OTHER_MODEL, effort: "xhigh" }),
  agent(SECOND_LENS, { agentType: "critic", model: AUTHOR_MODEL, effort: "xhigh" }),
]);

// You adjudicate. Agreement is not proof, and 1 verified serious defect blocks.
return { first, second };
