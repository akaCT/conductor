# Model notes

Verified on: 2026-10-12

The rule: re-verify when a model ships or after 90 days, whichever comes first. Model facts go stale within weeks, so they live in this file and not in the always-on doctrine. Each line below says where it came from. A line marked unverified is a gap, not a fact.

## What each alias runs on the first-party API

| Alias | Model | Needs Claude Code |
|---|---|---|
| `opus` | Opus 5.5 | 2.1.280 or later (earlier runtimes resolve it to Opus 5) |
| `sonnet` | Sonnet 5.5 | 2.1.284 or later (earlier runtimes resolve it to Sonnet 5) |
| `haiku` | Haiku 5.5 | 2.1.293 or later (earlier runtimes resolve it to Haiku 4.5) |
| `fable` | Fable 5.1 | 2.1.257 or later; not the default on any plan or provider |

Source: the vendor's model-config page, read 2026-10-12. If `claude update` fixes an old alias, no setting is needed. Conductor never writes a full model id into your settings.

## Effort

- Opus 5.5 and Sonnet 5.5 start at medium effort in Claude Code. A top-level `effortLevel` in user settings does not reach them. The per-model pin does: `modelSettings["claude-opus-5-5"].effortLevel` and `modelSettings["claude-sonnet-5-5"].effortLevel`. The installer offers both, 1 at a time, with your yes.
- Higher effort can use more of the plan's usage. This file makes no claim about quality or about how far a plan lasts.
- Every agent file pins its own `effort`, so a seat does not inherit the session level. Builder and scout run at high, critic, architect and judge at xhigh. Nothing runs at max.
- Open item (2026-10-12): whether a runtime older than the one that introduced a given effort level ignores or rejects an unsupported value in agent frontmatter is unverified. It is settled only by a live check on a real runtime. Until then the agent files carry `effort` on every runtime.

## Judge rungs

- Rung 1: `fable`, for accounts that have Fable 5.1 on a first-party runtime at 2.1.257 or later.
- Rung 3: `sonnet` at xhigh in a fresh context that sees only the artifact. It is the same model family as the builders, so it is a weaker second view than rung 1.
- Rung 2, a judge from another lab, comes in a later release. Nothing installs it yet.
- The judge holds Read, Grep and Glob only.

## Aliases off the first-party API

Some providers resolve an alias to an older model. Conductor writes no model id there. Vendor table, read 2026-10-12:

| Provider | `opus` | `sonnet` | `haiku` |
|---|---|---|---|
| Amazon Bedrock | not stated | Sonnet 4.5 | Haiku 4.5 |
| Google Cloud Agent Platform (Vertex) | not stated | Sonnet 4.5 | Haiku 4.5 |
| Claude Platform on AWS | not stated | Sonnet 4.6 | Haiku 4.5 |
| Microsoft Foundry | Opus 4.6 | Sonnet 4.5 | Haiku 4.5 |
| Bedrock Mantle | not stated | not stated | not stated |

The same data ships in `lib/facts.json` as `vendor_alias_table`, which the doctor reads.

## Provider detection

The provider counts as first-party only when none of these is non-empty, in the process environment or in the `env` block of your user settings: `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`, `CLAUDE_CODE_USE_ANTHROPIC_AWS`, `CLAUDE_CODE_USE_MANTLE`, and neither `ANTHROPIC_BASE_URL` nor `CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST` is set. An empty string counts as unset, and an `ANTHROPIC_BASE_URL` equal to the vendor's own address `https://api.anthropic.com` (any letter case, 1 optional trailing slash) counts as first-party. Source: the vendor's environment-variable page, read 2026-10-12. Which values besides `1` the provider variables accept is unverified; any non-empty value counts as set.

## Haiku 5.5

The vendor page says to use v2.1.293 or later with Haiku 5.5. Below that, `claude update` is the fix. Conductor never writes `ANTHROPIC_DEFAULT_HAIKU_MODEL`. If an earlier Conductor install recorded that value in its manifest, the installer offers to remove it. Haiku 5.5 behavior on structured output is unmeasured here, so keep a validator behind any schema you hand to the scout.

## Codex model map

Read on 2026-10-14 from https://learn.chatgpt.com/docs/models (the older developers.openai.com address redirects there).

| Conductor alias | Codex seat | Codex model |
|---|---|---|
| `opus` | architect | `gpt-6-astra` |
| `sonnet` | builder, critic | `gpt-6.1-sol` |
| `haiku` | scout | `gpt-6-luna` |

- The vendor says availability depends on the rollout, your sign-in method and your client. Enterprise and Edu accounts may need an administrator to enable a model first.
- The earlier GPT-5.4, GPT-5.4 mini and GPT-5.5 ids are retired for ChatGPT sign-in users (the last on 2026-10-14). The vendor names GPT-6 Sol as their replacement "when available" but gives it no entry of its own, so the map uses GPT-6.1 Sol, which it lists. No generated file names them.
- Codex effort: the page names no `model_reasoning_effort` key and no accepted values, so no effort key is written and the doctor shows each Codex agent as "not pinned".
