# Embeddings and Similarity Evals Design Spec

**Date:** 2026-06-12
**Status:** Approved design, pending implementation
**Tracker:** `crucible-d4w`.
**Research basis:** Anthropic develop-tests guidance (cosine-similarity consistency evals over paraphrase groups); follow-on from the Metric/Scale cycle (`crucible-2zw`), which gave similarity scores a scalar home in `Score.value`.
**Scope:** new `src/Crucible/Embed.hs` and `src/Crucible/LLM/Voyage.hs`; `src/Crucible/LLM/OpenAI.hs` (embeddings interpreter + config field); `src/Crucible/Eval.hs` (`SimilarTo`, pass rule, constraint change); `test/Spec.hs`; `app/Main.hs`; `docs/evals.md`; `docs/live-interpreter.md`.

## Motivation

crucible has no embedding capability, so two standard eval shapes are out
of reach: consistency checks over paraphrase groups (similar questions
should get semantically similar answers) and per-case semantic match
against a reference. An Embed effect also opens later reuse (memory,
retrieval) beyond evals.

Provider reality shapes the design: Anthropic has no embeddings endpoint
(they point customers at Voyage AI), so the live interpreters are OpenAI
(`/v1/embeddings`) and Voyage.

## Decisions taken during design

- Full `Embed` dynamic effect with the house interpreter grammar, not
  provider-level functions or an eval-internal helper.
- Providers: OpenAI AND Voyage AI in this cycle.
- Eval surface: BOTH the group `consistency` helper and a per-case
  `SimilarTo` expectation, accepting the breaking `Embed :> es` ripple
  through the scoring functions.
- `Embed.none` ships as the one-line migration path for callers that
  never use `SimilarTo`.

## Design

### 1. `Crucible.Embed` (new module)

```haskell
data Embed :: Effect where
  EmbedText :: Text -> Embed m [Double]

embed :: (Embed :> es) => Text -> Eff es [Double]

-- | Canned vectors, popped per call (mirrors runLLMScripted, including
-- its behaviour when the script runs dry).
runEmbedScripted :: [[Double]] -> Eff (Embed : es) a -> Eff es a

-- | For programs that never embed: discharges the effect and errors
-- with a clear message on first use. The one-line migration for
-- existing scoreM/runEval callers.
none :: Eff (Embed : es) a -> Eff es a

-- | Pure cosine similarity; 0 when either vector is all zeros.
cosine :: [Double] -> [Double] -> Double

-- | Mean pairwise cosine over a paraphrase group's outputs; groups of
-- zero or one text score 1.0. The group-shaped consistency eval from
-- the develop-tests guidance, deliberately OUTSIDE Expectation: it
-- compares outputs across runs, not one output against one expectation.
consistency :: (Embed :> es) => [Text] -> Eff es Double
```

Module used qualified (`Embed.none`, `Embed.cosine`) except the `Embed`
type, `embed`, and `runEmbedScripted`, which follow the `Crucible.LLM`
export style.

### 2. OpenAI interpreter (`Crucible.LLM.OpenAI`)

```haskell
runEmbed :: OpenAIConfig -> Eff (Embed : es) a -> Eff es a
```

POST `{baseUrl}/embeddings`, body `{"input": <text>, "model": <embedModel>}`,
decoding `data[0].embedding`. Reuses the module's manager creation, retry
policy (full-jitter backoff on its retryable classification), and error
type. `OpenAIConfig` gains an `embedModel :: Text` field;
`defaultOpenAIConfig` sets `"text-embedding-3-small"`. Record-update
construction sites are unaffected; this is a breaking change only for
positional construction, which crucible does not use.

### 3. `Crucible.LLM.Voyage` (new provider module)

Mirrors the structure of the other provider modules:

```haskell
data VoyageConfig = VoyageConfig { apiKey :: Text, model :: Text, baseUrl :: Text }
defaultVoyageConfig :: Text -> VoyageConfig   -- model "voyage-3.5-lite"
newVoyageManager :: VoyageConfig -> IO Manager
data VoyageError = ...                        -- status / decode errors, like AnthropicError
runEmbed :: VoyageConfig -> Eff (Embed : es) a -> Eff es a
```

(As built: VoyageConfig carries the house timeout/retry knobs
(timeoutSecs, maxRetries, baseDelayMicros) instead of baseUrl; the URL is
hardcoded exactly as the OpenAI module hardcodes its endpoints.)

POST `https://api.voyageai.com/v1/embeddings`, headers
`Authorization: Bearer <key>`, body `{"input": [<text>], "model": <model>}`,
decoding `data[0].embedding`. Retryable: 429, 5xx, timeouts;
non-retryable: other 4xx. Full-jitter backoff per the house pattern. The
default model name is verified against the live API during
implementation (the implementer corrects it from the API's error message
if it has moved). Key from `VOYAGE_API_KEY`. Used qualified:
`Voyage.runEmbed cfg`.

### 4. `SimilarTo` expectation and the pass rule (`Crucible.Eval`)

```haskell
| SimilarTo Double Text   -- ^ pass threshold, reference text: embeds both
                          --   the reference and the output, scoring cosine
                          --   similarity clamped to [0,1], passing at
                          --   value >= threshold
```

`scoreWith` dispatch: embed the reference, embed the rendered output
(two `embed` calls per case), score `max 0 (cosine ref out)` with a
`"cosine = <value>"` rationale. Deterministic given the embedder: no
votes, no dissent. `passes` gains `SimilarTo t _ -> v >= t`.

**Breaking change, stated plainly:** `scoreWith` gains `Embed :> es`,
rippling to `scoreM`, `scoreN`, `runEval`, `runEvalN`, `runEvalWith`. (As built: also `Crucible.Skill.testSkill` and `Crucible.Skill.Improve.improveSkill`, which call `runEval` internally; found during planning.)
Every existing crucible call site adds one `Embed.none` (or
`runEmbedScripted`) wrapper; roughly thirty mechanical edits in
`test/Spec.hs` plus the demo. Downstream, manifest-evals imports
`scoreN` and needs the same one-line wrapper at its runEff edge on its
next pin bump; this goes in the session handoff and the bd memory.
`judge`/`judgeWith`/`judgeN` and `calibrate` do not dispatch
expectations and are untouched.

## Demo (`app/Main.hs`)

- In the OpenAI-key-gated block: `consistency` over two paraphrase
  answers (printing `consistency: <value>`) and one `SimilarTo` case in
  a small `runEval` (printing the report line). Uses `OpenAI.runEmbed`.
- A new `VOYAGE_API_KEY`-gated block: embed one sentence via
  `Voyage.runEmbed`, print the vector length (proves auth, request
  shape, decode). Key absence skips cleanly with a message, like the
  OpenAI gate.

## Manual

- `docs/evals.md`: `SimilarTo` joins the top-of-page `Expectation`
  listing and the grader-choosing ladder; the Limits paragraph drops
  "embedding cosine similarity is tracked separately" and gains the
  distinction between per-case `SimilarTo` and group `consistency`
  (with `consistency` shown); a note that `SimilarTo` needs an `Embed`
  interpreter at the edge and that `Embed.none` serves programs without
  similarity cases.
- `docs/live-interpreter.md`: an embeddings section covering the
  effect, both interpreters (`OpenAI.runEmbed`, `Voyage.runEmbed`), the
  `embedModel` config field, and `Embed.none`.
- House style: no emdashes, no hype, no manifest mentions in public
  docs (the migration note for the sibling project lives in the spec
  and handoff only).

## Testing (hermetic; scripted vectors)

- `cosine`: orthogonal vectors 0, identical 1, the zero-vector guard 0,
  one hand-derived non-trivial value.
- `consistency`: canned vectors via `runEmbedScripted` (e.g. three texts,
  hand-derived mean pairwise cosine); singleton and empty groups pin 1.0.
- `SimilarTo` under `runEmbedScripted`: pass above threshold, fail
  below, negative cosine clamps to 0; the mixed-dataset passRate check
  extended with a `SimilarTo` case.
- `Embed.none`: a `SimilarTo` case under `none` raises the clear error
  (caught with `try`); a `Metric`/`Rubric` dataset under `none` scores
  exactly as before the constraint change.
- Voyage: pure request-encoder and response-decoder checks (the module
  factors them purely, mirroring the other providers).
- Live: the demo consistency, `SimilarTo`, and Voyage lines before
  merge (Voyage line only if `VOYAGE_API_KEY` is present).

## Non-goals

- Usage accounting for embeddings (`usageEmbed` variants): nothing
  consumes embedding token counts yet; add on demand.
- Embed cassettes (record/replay): scripted vectors cover hermetic
  testing; cassettes earn their keep only with expensive live suites.
- Embed members in `Fallback` chains: fallback covers `LLM` and `Chat`;
  no demonstrated need for multi-provider embedding resilience.
- Batched embedding calls (lists per request): single-text calls keep
  the effect minimal; batching is an optimization with no current
  consumer.
- Similarity metrics beyond cosine (dot product, Euclidean): cosine is
  the standard for normalized text embeddings and the only one the
  guidance uses.
