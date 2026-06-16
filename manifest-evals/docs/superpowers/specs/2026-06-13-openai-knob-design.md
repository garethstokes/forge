# OpenAI-judge provider knob — Design

**Status:** Approved (batch brainstorm 2026-06-13). · **Date:** 2026-06-13

**Goal:** A grader can route its LLM judging through crucible's
`Crucible.LLM.OpenAI` instead of Anthropic, selected by a `provider` key in the
grader-version config jsonb. The live grading edge dispatches per grader.

## Decisions (user-approved)
- `provider` key in the grader-version config (`"anthropic"` default | `"openai"`).
- Per-grader, persisted (lives where `model`/`votes` already live).
- CLI plumbs both keys; `OPENAI_API_KEY` required only when a grader is openai.

## Facts (verified)
crucible `Crucible.LLM.OpenAI` is API-isomorphic to `Anthropic`:
`OpenAIConfig {apiKey, model, embedModel, maxTokens, timeoutSecs, maxRetries,
baseDelayMicros, streamIdleSecs}`, `defaultOpenAIConfig :: Text -> OpenAIConfig`
(model `"gpt-4o-mini"`), `run :: (IOE :> es) => OpenAIConfig -> Eff (LLM:es) a
-> Eff es a`, `OpenAIError` (same constructor shapes as `AnthropicError`).
The live edge today is `Evals.Grade.Anthropic` (`gradeCfg`/`liveGradeRunner`/
`liveCriterionJudge`, taking one `Text` key); `cfgFromParams :: Text -> Maybe
Text -> Value -> AnthropicConfig` (in `Evals.Execute.Anthropic`) maps the shared
`max_tokens`/`timeout`/`retries` jsonb knobs. Importers of `Evals.Grade.Anthropic`:
`app/Main.hs` (`liveCriterionJudge`, `liveGradeRunner`), `test/GradeSpec.hs`
(`gradeCfg`). `votesFrom :: Value -> Int` lives in `Evals.Grade`.

## 1. Config helpers
- `Evals.Grade.providerFrom :: Value -> Text` — reads `provider` from the grader
  config, default `"anthropic"` (non-object → `"anthropic"`). Exported beside
  `votesFrom`.
- New `Evals.Execute.OpenAI` with `openaiCfgFromParams :: Text -> Maybe Text ->
  Value -> OpenAIConfig` — the OpenAI mirror of `cfgFromParams` (same
  `max_tokens`/`timeout`/`retries` knob names onto `maxTokens`/`timeoutSecs`/
  `maxRetries`; optional `model` override over `defaultOpenAIConfig`). Parallels
  `Evals.Execute.Anthropic` (execution OpenAI support is out of scope; only the
  config builder is added).

## 2. The live edge — rename + dispatch
Rename `Evals.Grade.Anthropic` → **`Evals.Grade.Live`** (it stops being
Anthropic-only). It exports `LiveKeys (..)`, `gradeCfg` (Anthropic config,
unchanged — `GradeSpec` uses it), `openaiCfg`, `liveGradeRunner`,
`liveCriterionJudge`.

```haskell
data LiveKeys = LiveKeys { anthropic :: Text, openai :: Maybe Text }

openaiCfg :: Text -> Value -> OpenAIConfig          -- = openaiCfgFromParams key (modelFrom cfgV) cfgV

liveGradeRunner   :: LiveKeys -> GradeRunner
liveCriterionJudge :: LiveKeys -> CriterionJudge
```

Both `liveGradeRunner` and `liveCriterionJudge` read `providerFrom cfgV` and
dispatch:
- `"openai"` → if `keys.openai` is `Nothing`, return `Left (LlmError "grader
  provider is openai but OPENAI_API_KEY is not set")`; else run the SAME crucible
  action through `OpenAI.run (openaiCfg k cfgV)`, mapping a thrown `OpenAIError`
  to `LlmError`.
- otherwise → today's Anthropic path (`Anthropic.run (gradeCfg keys.anthropic
  cfgV) …`).

The crucible action is factored into a `let` and shared by both branches (after
`Embed.none`, its type `Eff (LLM:es) a` accepts either interpreter), so only the
interpreter + config + error type differ. The `Decided`/`AllErrored`/
`AllAbstained` verdict handling and the `votesFrom`/`JudgeOpts` wiring are
unchanged.

## 3. CLI — both keys
`app/Main.hs`: a `liveKeys :: IO LiveKeys` helper reads `ANTHROPIC_API_KEY`
(required) + `OPENAI_API_KEY` (optional, `lookupEnv`). The `score` arm passes
`liveGradeRunner ks`/`liveCriterionJudge ks`; the `metaeval report` `live`
branch builds `Live (liveCriterionJudge ks)`. Imports update from
`Evals.Grade.Anthropic` to `Evals.Grade.Live`.

## 4. Testing
- **Pure:** `providerFrom` (default `"anthropic"`; reads `"openai"`; non-object →
  `"anthropic"`). `openaiCfgFromParams` builds an `OpenAIConfig` with a `model`
  override and the three knob overrides (`max_tokens`/`timeout`/`retries`),
  defaults otherwise — assert the fields. (In `GradeSpec`'s config spec, beside
  the existing `gradeCfg` test.)
- **Live dispatch** is edge-only (no unit test, exactly as the existing Anthropic
  edge — verified live, not in CI). **Caveat:** the real OpenAI call is NOT
  human-verified this slice; flagged for a morning smoke.

## 5. Out of scope
- OpenAI for target EXECUTION (only the grading/judge edge).
- An OpenAI run-recording/replay path; embeddings.
- A live OpenAI integration test.
