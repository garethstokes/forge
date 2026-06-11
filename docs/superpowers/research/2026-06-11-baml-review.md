# BAML vs crucible: gap analysis (June 2026)

Status: research note, not published. Survey of BAML (boundaryml.com) as of June 2026
against crucible's current surface, with concrete candidates for crucible.

## Summary

BAML is a DSL plus codegen toolchain for typed LLM functions; crucible is a Haskell
library doing the same job with codecs and effect interpreters. The overlapping core
(schema-driven prompts, tolerant parsing, retries, tests next to the prompt) is at
parity; crucible's withTests/testSkill was taken from BAML's test blocks. BAML is
ahead on client resilience policy (fallback and round-robin across providers as
declarative client strategies), semantic streaming of partial typed values
(@stream.done, @stream.not_null, StreamState), output refinements (@assert/@check),
per-call introspection (Collector), and multimodal inputs. crucible is ahead on
evaluation (LLM judge with voting, calibration, grounding), deterministic replay
(cassettes), and prompt optimization in the library (improveSkill). The top three
adoptions: provider fallback/round-robin as interpreter combinators, semantic
streaming of partial typed values, and assert/check as codec-level refinements.

## What BAML ships now

Release cadence context: the 0.2xx runtime line reached 0.222.0 on 2026-04-27
(changelog: https://github.com/BoundaryML/baml/blob/canary/CHANGELOG.md), and the
GitHub releases page now also carries a separate "BAML Language" artifact line at
0.12.0 dated 2026-06-11 (https://github.com/BoundaryML/baml/releases), which tracks
the new compiler work (lambdas, expressions) rather than the client runtime.

### Client policies: retry, fallback, round-robin

A `retry_policy` block (constant_delay or exponential_backoff with multiplier and
max delay) attaches by name to any client
(https://docs.boundaryml.com/ref/llm-client-strategies/retry-policy). A `fallback`
provider takes an ordered strategy list of clients and tries them in sequence on
failure; fallbacks nest, and a retry policy on a fallback retries the whole chain
after all members fail (https://docs.boundaryml.com/ref/llm-client-strategies/fallback).
A `round-robin` provider rotates through a client list per call, with a randomized
start index in production, and rotates on retry
(https://docs.boundaryml.com/ref/llm-client-strategies/round-robin). The strategy
members can be different providers entirely, so "GPT, then Claude, then a local
model" is a one-block config.

### Semantic streaming of partial structured output

BAML repairs partial JSON mid-stream and emits a series of semantically valid
partial objects, with field-level control over what may appear before it is final
(https://docs.boundaryml.com/guide/baml-basics/streaming):

- `@stream.done`: the field or type is only emitted once complete (atomic values).
- `@stream.not_null`: the containing object is withheld until this field has a
  value (discriminators, required metadata).
- `@stream.with_state`: wraps the field in `StreamState` carrying whether it has
  finished streaming (UI loading states).

The attribute combination determines the generated partial type: plain `T` streams
as `Partial[T]?`, `@stream.done` as `T?`, `@stream.done @stream.not_null` as `T`.
Known gap on their side: semantic streaming does not yet work with dynamic types
(https://github.com/BoundaryML/baml/issues/2980).

### Assert and check constraints on output types

`@assert` and `@check` annotate fields, whole classes (`@@assert`), union arms, and
container elements, with Jinja expressions over `this`
(https://docs.boundaryml.com/guide/baml-advanced/checks-and-asserts). Asserts are
hard: a failing top-level assert raises BamlValidationError; failing asserts on
container elements remove the element. Checks are soft: the value comes back wrapped
in a `Checked` type with a per-check pass/fail map, so callers can branch on quality
without losing the data.

### Dynamic and runtime types (TypeBuilder)

Classes and enums marked `@@dynamic` can be extended at runtime through a
TypeBuilder in the client language: add enum variants from a database, add fields
known only at runtime, and the prompt schema follows
(https://docs.boundaryml.com/guide/baml-advanced/dynamic-types,
https://docs.boundaryml.com/ref/baml_client/type-builder). Test blocks can carry
`type_builder` blocks for test-scoped type modifications.

### Collectors

A `Collector` passed via `baml_options` records every LLM invocation behind a
function call: input/output/cached token counts, start time, duration,
time-to-first-token for streams, full raw HTTP request and response, and one entry
per attempt including retries and fallbacks with a `selected` flag marking which
attempt the parser used. `.usage` aggregates across calls; multiple collectors can
observe the same call
(https://docs.boundaryml.com/guide/baml-advanced/collector-track-tokens).

### Test blocks

`test` blocks live next to functions, take typed args (including media files), and
carry `@@assert` / `@@check` Jinja expressions over `_.result`, `_.checks.$NAME`,
and `_.latency_ms` (https://docs.boundaryml.com/guide/baml-basics/testing-functions).
Run in the VSCode playground or via `baml-cli test` with parallelism control. The
0.221.0 release added dynamic test/testset expression syntax.

### Multimodal inputs

`image`, `audio`, `pdf`, and `video` are first-class input types, constructed from
URLs, base64, or local files, usable in both prompts and test args
(https://docs.boundaryml.com/ref/baml_client/pdf,
https://boundaryml.com/blog/audio-support). Video and Bedrock video support landed
in 0.213.0; Go got multimodal in the same release.

### Playground and prompt views

The VSCode extension renders the exact prompt (including multimodal assets) and the
raw API request before anything is sent, with token counts, inline test runners,
and test history (https://docs.boundaryml.com/guide/baml-basics/prompting-with-baml).
0.215.0 added a prompt optimization visualizer; 0.214.0 added a static control flow
visualizer and a "toon" Jinja filter for token-efficient serialization.

### New in 2026: the language itself is growing

The last six months were mostly about turning BAML from a schema DSL into a small
programming language: lambda expressions, optional chaining `?.` and null
coalescing `??`, void returns, folder namespaces, `baml grep` / `baml describe`
for agent-oriented semantic search over BAML code, a native Rust SDK, stack traces
with source lines, and `build_request` for constructing raw requests without
sending (https://docs.boundaryml.com/changelog/changelog). The Workflows tech
preview lets multi-call pipelines be written in BAML itself (expressions, function
application, no loops yet), with agentic loops named as the roadmap priority
(https://boundaryml.com/blog/workflows). None of this is production-ready by their
own warning, but it shows the direction: orchestration moving into the DSL.

## Side-by-side

| Capability | BAML | crucible | Verdict |
|---|---|---|---|
| Typed structured output | Function + class schema, codegen per language | `Skill i o` + autodocodec codecs, schema injected into prompt | Parity, different idioms |
| Tolerant parsing | SAP parser fixes malformed/partial JSON | `stripToJson` balanced-bracket extraction + codec decode | Parity for whole replies; BAML also repairs partial JSON mid-stream |
| Decode-failure retries | Parser is tolerant; retry_policy is for network errors only | `call` re-prompts with the parse error and schema, budgeted | crucible ahead: error feedback loop to the model |
| Retry policy (transport) | Declarative per-client, constant/exponential | `withAnthropicRetry` / `withOpenAIRetry`, full jitter backoff, per provider | Parity per provider |
| Fallback across providers | `provider fallback` strategy list, nestable | None | BAML ahead |
| Round-robin load spread | `provider round-robin`, rotates on retry | None | BAML ahead |
| Streaming text deltas | Yes, per-language stream APIs | `Emit` effect + Anthropic/OpenAI stream interpreters | Parity |
| Semantic streaming of partial typed values | `Partial[T]`, @stream.done / not_null / with_state | JSONL rows only (`Crucible.Rows`); single-object partial decode explicitly out of scope | BAML ahead |
| Output refinements | @assert (hard) and @check (soft, `Checked` wrapper) | None at codec level; Predicate exists only in eval cases | BAML ahead |
| Runtime/dynamic schemas | @@dynamic + TypeBuilder API | Codecs are ordinary values; `enum` over a runtime list works today, but the pattern is undocumented | Mostly parity in power, BAML ahead in ergonomics/docs |
| Usage/introspection | Collector: per-call tokens, timing, TTFT, raw HTTP, retry visibility, selected flag | `Usage` monoid (input/output tokens) + `estimateCost` | BAML ahead |
| Tests next to the prompt | test blocks, @@assert/@@check, latency asserts, CLI + playground | `withTests`/`testSkill`, Exactly/Predicate/Rubric, Report | Parity on the core (crucible adopted this from BAML); BAML has latency asserts, crucible has rubric grading |
| Few-shot management | Hand-written in Jinja prompt | `withExamples`, `examplesFromTests` moves cases so taught and tested never overlap | crucible ahead |
| Reasoning-before-answer | Hand-rolled in prompt | `withReasoning` wraps the output contract | crucible ahead |
| Multimodal inputs | image, audio, pdf, video first-class | Text-only `Message` | BAML ahead |
| Prompt visibility | Playground renders prompt + raw request pre-send | `prompt :: Skill i o -> i -> [Message]` returns exact messages; no UI | Parity in capability, BAML ahead in tooling |
| Deterministic replay | None (Collector records, nothing replays) | record/replay cassettes for both providers, LLM and Chat | crucible ahead |
| Eval / judge | Asserts and checks only; no LLM judge | Judge with reason-then-verdict, voting, calibrate (kappa), grounding (claim decomposition) | crucible ahead |
| Prompt optimization | Visualizer in playground (manual) | `improveSkill` hill-climbs preamble/constraints against attached tests | crucible ahead |
| Providers | Many (OpenAI, Anthropic, Gemini, Bedrock, Vertex, Azure, Ollama, openai-generic) | Anthropic + OpenAI | BAML ahead on breadth |
| Orchestration | Workflows tech preview, in-DSL expressions, no loops yet | Full host language; effectful composition is the whole design | crucible ahead (it never left the host language) |

## Crucible candidates

Ranked by value to crucible's existing users, with a concrete shape for each.

1. Provider fallback and round-robin as interpreter combinators. This is the
   biggest genuine gap: a transient Anthropic outage today fails the program after
   `withAnthropicRetry` exhausts. The shape fits crucible's design well because
   policy belongs at the `runEff` edge, exactly where interpreters already live.
   Something like `Fallback.run :: [Interpreter LLM] -> Eff (LLM : es) a -> Eff es a`
   where an `Interpreter LLM` packages a provider config plus its retryable-error
   predicate (both providers already export `isRetryable`). Round-robin is the same
   list with rotation state. Match BAML's semantics: retry within a member, then
   advance; a policy on the composite retries the whole chain. Nesting falls out
   for free. Cassette recording of a fallback run should note which member answered.

2. Semantic streaming of partial typed values. crucible's streaming docs declare
   incremental typed decoding of a single object out of scope; BAML shows the
   feature is both wanted and tractable, and their own issue tracker shows the hard
   edge (dynamic types). A crucible version would be a partial-decode pass:
   `runPartial :: JSONCodec o -> (Partial o -> Eff es ()) -> Eff (Emit : es) r -> ...`
   where the interpreter closes unbalanced brackets in the buffer and decodes
   through a derived tolerant codec in which every field is optional. The
   `@stream.done` analogue is a per-field annotation on the codec (see candidate 3:
   the same refinement mechanism can carry stream gating). Start with records of
   scalars and lists; that covers the UI use case BAML is targeting.

3. Assert and check as codec-level refinements. crucible already has the perfect
   consumer for hard asserts: `call`'s decode-retry loop. A refinement that fails
   decode (`refine :: Text -> (a -> Bool) -> JSONCodec a -> JSONCodec a`) means the
   violation message is fed back to the model and retried, which is strictly better
   than BAML's behavior (BamlValidationError raised to the caller). Soft checks are
   a separate wrapper, `checked :: [(Text, a -> Bool)] -> JSONCodec a -> JSONCodec (Checked a)`,
   mirroring BAML's `Checked` with a name-to-pass map. Keep refinements out of the
   advertised JSON schema (or render them as schema `description` text) so the
   contract stays honest.

4. Per-call introspection (Collector parity). `Usage` is two ints; BAML's Collector
   records per-attempt timing, TTFT, raw HTTP, and which attempt was selected.
   crucible's cassettes already capture raw request/response text, so the gap is
   metadata: a `CallLog` list (provider, model, duration, TTFT, usage, attempt
   number, selected) accumulated by a `logged` interpreter wrapper, with `Usage`
   remaining the cheap default. This becomes more valuable the moment candidate 1
   exists, because fallback decisions need to be observable.

5. Multimodal inputs. `Message` carries `Text` only. Adding an image/PDF content
   block to `Message` (both providers support it on the wire) unlocks extraction
   skills over documents, which is BAML's best demo category. Larger surface change
   than 1 to 4; worth a spec of its own.

6. Dynamic codecs: document, do not build. BAML needs TypeBuilder because its types
   are compiled. crucible codecs are runtime values; `enum (zip labels values)` over
   a list fetched from a database already works. The gap is a docs section showing
   the category-from-database pattern, not new machinery.

7. Latency assertions in tests. BAML test asserts can reference `_.latency_ms`.
   `Case`/`Expectation` could grow a wall-clock predicate, but it only makes sense
   under live interpreters and would be noise under cassettes. Low priority.

## What BAML does not have that crucible does

Kept here so the review cuts both ways.

- An evaluation stack. BAML's quality story stops at asserts and checks. crucible
  has rubric-graded cases via an LLM judge with reason-then-verdict ordering,
  verdict repair, majority voting, judge calibration against human labels (kappa),
  and grounding via claim decomposition. BAML has no judge at all.
- Deterministic replay. Cassette record/replay for both providers makes CI runs
  free and reproducible. BAML's Collector observes but cannot replay; their tests
  hit live models or nothing.
- In-library prompt optimization. `improveSkill` hill-climbs preamble and
  constraints against the attached tests with honesty rails documented (calibrate
  first, hold out cases). BAML's prompt optimization visualizer is a manual tool.
- Few-shot discipline. `examplesFromTests` moves cases between teach and test sets
  so a demonstrated case can never inflate the test score. BAML has no equivalent
  concept; examples are hand-pasted into Jinja.
- Host-language orchestration with typed effects. BAML is mid-flight building
  expressions, lambdas, and (eventually) loops into its DSL because orchestration
  outgrew it. crucible programs never left Haskell, so composition, branching, and
  state cost nothing and were never a roadmap item.
- A reasoning wrapper (`withReasoning`) as a one-line transform rather than a
  hand-edited prompt and schema.

What crucible already took from BAML: tests declared next to the prompt
(`withTests` is explicitly the BAML test-block pattern, acknowledged in
docs/typed-functions.md), and schema-in-prompt as the structured output mechanism
rather than provider-side JSON mode.

## Sources

- Changelog (docs): https://docs.boundaryml.com/changelog/changelog
- Changelog (repo): https://github.com/BoundaryML/baml/blob/canary/CHANGELOG.md
- Releases: https://github.com/BoundaryML/baml/releases
- Retry policy: https://docs.boundaryml.com/ref/llm-client-strategies/retry-policy
- Fallback: https://docs.boundaryml.com/ref/llm-client-strategies/fallback
- Round-robin: https://docs.boundaryml.com/ref/llm-client-strategies/round-robin
- Streaming and semantic attributes: https://docs.boundaryml.com/guide/baml-basics/streaming
- Semantic streaming with dynamic types (open issue): https://github.com/BoundaryML/baml/issues/2980
- Checks and asserts: https://docs.boundaryml.com/guide/baml-advanced/checks-and-asserts
- Dynamic types: https://docs.boundaryml.com/guide/baml-advanced/dynamic-types
- TypeBuilder reference: https://docs.boundaryml.com/ref/baml_client/type-builder
- Collector: https://docs.boundaryml.com/guide/baml-advanced/collector-track-tokens
- Testing functions: https://docs.boundaryml.com/guide/baml-basics/testing-functions
- Workflows tech preview: https://boundaryml.com/blog/workflows
- Audio support: https://boundaryml.com/blog/audio-support
- Pdf type reference: https://docs.boundaryml.com/ref/baml_client/pdf
- Prompting in BAML (playground): https://docs.boundaryml.com/guide/baml-basics/prompting-with-baml
- BAML repo: https://github.com/BoundaryML/baml
