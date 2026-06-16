# OpenAI-judge provider knob Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** A grader routes judging through crucible's OpenAI interpreter via a `provider` config key.

**Spec:** `docs/superpowers/specs/2026-06-13-openai-knob-design.md`

**Repo facts (verified, verbatim where it matters):**
- crucible `Crucible.LLM.OpenAI` exports `OpenAIConfig (..)`, `defaultOpenAIConfig :: Text -> OpenAIConfig`, `OpenAIError (..)`, `run :: (IOE :> es) => OpenAIConfig -> Eff (LLM : es) a -> Eff es a`. `OpenAIConfig {apiKey :: Text, model :: Text, embedModel :: Text, maxTokens :: Int, timeoutSecs :: Int, maxRetries :: Int, baseDelayMicros :: Int, streamIdleSecs :: Int}`; `defaultOpenAIConfig key` sets model `"gpt-4o-mini"`. Isomorphic to `Crucible.LLM.Anthropic` (`AnthropicConfig`/`AnthropicError`/`run`).
- `src/Evals/Execute/Anthropic.hs` `cfgFromParams` (the pattern to mirror):
  ```haskell
  cfgFromParams :: Text -> Maybe Text -> Value -> AnthropicConfig
  cfgFromParams key mModel paramsVal = base
    { maxTokens   = intParam "max_tokens" base.maxTokens
    , timeoutSecs = intParam "timeout"    base.timeoutSecs
    , maxRetries  = intParam "retries"    base.maxRetries }
    where
      base :: AnthropicConfig
      base = case mModel of
        Just m  -> (defaultAnthropicConfig key) { model = m }
        Nothing -> defaultAnthropicConfig key
      intParam :: AT.Key -> Int -> Int
      intParam k dflt = case paramsVal of
        Object o -> maybe dflt id (AT.parseMaybe (AT..: k) o)
        _        -> dflt
  ```
- `src/Evals/Grade.hs` `votesFrom :: Value -> Int = maybe 1 id (AT.parseMaybe (AT.withObject "config" (\o -> o AT..:? "votes" AT..!= 1)) v)`. Module exports list includes `votesFrom`.
- `src/Evals/Grade/Anthropic.hs` (full) — `module Evals.Grade.Anthropic (gradeCfg, liveGradeRunner, liveCriterionJudge)`; `gradeCfg key cfgV = cfgFromParams key (modelFrom cfgV) cfgV where modelFrom = AT.parseMaybe (AT.withObject "config" (AT..: "model"))`; `liveGradeRunner key gv expectation rendered = try (runEff (Anthropic.run (gradeCfg key cfgV) (Embed.none (Eval.scoreN (votesFrom cfgV) id expectation rendered)))) >>= \case { Right s -> pure (Right s); Left (e :: AnthropicError) -> pure (Left (LlmError (T.pack (show e)))) } where Aeson cfgV = gv.config`; `liveCriterionJudge key gv transcriptTxt c = try (runEff (Anthropic.run (gradeCfg key cfgV) (Judge.vote True (Judge.defaultJudgeOpts { Judge.votes = votesFrom cfgV }) (renderCriterion c) transcriptTxt))) >>= \case { Right (Judge.Decided p w _ _ _) -> ...; Right (Judge.AllErrored m) -> ...; Right (Judge.AllAbstained m) -> ...; Left (e :: AnthropicError) -> ... } where Aeson cfgV = gv.config`. Imports: `qualified Crucible.Embed as Embed`, `qualified Crucible.Eval as Eval`, `qualified Crucible.Eval.Judge as Judge`, `Crucible.LLM.Anthropic (AnthropicConfig, AnthropicError)` + `qualified ... as Anthropic`, `Manifest (Aeson (..))`, `Evals.Execute (ExecError (..))`, `Evals.Execute.Anthropic (cfgFromParams)`, `Evals.Grade (CriterionJudge, CriterionVerdict (..), GradeRunner, renderCriterion, votesFrom)`, `Evals.Schema`.
- Importers of `Evals.Grade.Anthropic`: `app/Main.hs` (`import Evals.Grade.Anthropic (liveCriterionJudge, liveGradeRunner)`), `test/GradeSpec.hs` (`import Evals.Grade.Anthropic (gradeCfg)`).
- `app/Main.hs` `score` arm reads `key <- requireEnv "ANTHROPIC_API_KEY"` then `scoreRun pool conc (liveGradeRunner (T.pack key)) (liveCriterionJudge (T.pack key)) (RunId rid) gvs`. `metaeval report` `live` branch: `"live" -> Live . liveCriterionJudge . T.pack <$> requireEnv "ANTHROPIC_API_KEY"`. `requireEnv :: String -> IO String` and `lookupEnv` (from `System.Environment`, already imported for `lookupEnv`? verify) are available.
- `test/GradeSpec.hs` has `configSpec` and `gradeCfgSpec` (pure config tests); it imports `gradeCfg` and `Crucible.LLM.Anthropic (AnthropicConfig (..), defaultAnthropicConfig)`. Build/test: `nix develop -c zinc build` / `nix develop -c zinc test 2>&1 | tail -8`.

---

### Task 1: `providerFrom` + `Evals.Execute.OpenAI.openaiCfgFromParams` (TDD)

**Files:** `src/Evals/Grade.hs`, `src/Evals/Execute/OpenAI.hs` (new), `test/GradeSpec.hs`.

- [ ] **Step 1: failing tests.** In `test/GradeSpec.hs` (in `configSpec` or `gradeCfgSpec` — wherever the `gradeCfg`/`votesFrom` pure tests live; add `import Evals.Execute.OpenAI (openaiCfgFromParams)` and `import Crucible.LLM.OpenAI (OpenAIConfig (..))`, and `providerFrom` to the `Evals.Grade` import list):

```haskell
  expect "provider default anthropic" (providerFrom (object []) == "anthropic")
  expect "provider reads openai" (providerFrom (object ["provider" .= ("openai" :: Text)]) == "openai")
  expect "provider non-object -> anthropic" (providerFrom (String "x") == "anthropic")
  let oc = openaiCfgFromParams "k" (Just "gpt-4.1")
            (object ["max_tokens" .= (50 :: Int), "timeout" .= (7 :: Int), "retries" .= (2 :: Int)])
  expect "openaiCfg model override" (oc.model == "gpt-4.1")
  expect "openaiCfg knobs" (oc.maxTokens == 50 && oc.timeoutSecs == 7 && oc.maxRetries == 2)
  expect "openaiCfg key" (oc.apiKey == "k")
  let od = openaiCfgFromParams "k" Nothing (object [])
  expect "openaiCfg default model" (od.model == "gpt-4o-mini")
```
(`String`/`object`/`(.=)` from Data.Aeson — already imported in GradeSpec.) Run `nix develop -c zinc test 2>&1 | tail -6` — compile FAIL (`providerFrom`/`openaiCfgFromParams` missing).

- [ ] **Step 2: `providerFrom`.** In `src/Evals/Grade.hs`, add to the export list `, providerFrom` (beside `votesFrom`), and define beside `votesFrom`:
```haskell
-- | The @provider@ key of a grader config object: "anthropic" (default) or
-- "openai". A non-object config yields "anthropic".
providerFrom :: Value -> Text
providerFrom v = maybe "anthropic" id (AT.parseMaybe parser v)
  where parser = AT.withObject "config" (\o -> o AT..:? "provider" AT..!= "anthropic")
```

- [ ] **Step 3: `Evals.Execute.OpenAI`.** Create `src/Evals/Execute/OpenAI.hs` mirroring `Evals.Execute.Anthropic`'s `cfgFromParams`:
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | OpenAI config plumbing for the grading edge: map the shared LLM knobs of a
-- config jsonb onto an 'OpenAIConfig'. Mirrors "Evals.Execute.Anthropic".
module Evals.Execute.OpenAI (openaiCfgFromParams) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Types as AT
import Data.Text (Text)

import Crucible.LLM.OpenAI (OpenAIConfig (..), defaultOpenAIConfig)

-- | Optional model override plus max_tokens/timeout/retries from the jsonb.
openaiCfgFromParams :: Text -> Maybe Text -> Value -> OpenAIConfig
openaiCfgFromParams key mModel paramsVal = base
  { maxTokens   = intParam "max_tokens" base.maxTokens
  , timeoutSecs = intParam "timeout"    base.timeoutSecs
  , maxRetries  = intParam "retries"    base.maxRetries
  }
  where
    base :: OpenAIConfig
    base = case mModel of
      Just m  -> (defaultOpenAIConfig key) { model = m }
      Nothing -> defaultOpenAIConfig key
    intParam :: AT.Key -> Int -> Int
    intParam k dflt = case paramsVal of
      Object o -> maybe dflt id (AT.parseMaybe (AT..: k) o)
      _        -> dflt
```
zinc discovers the module under `src/`. Run `nix develop -c zinc test 2>&1 | tail -6` — the Task-1 tests pass; everything else green. (The new module needs no new lib dep — `crucible` already in `[build.lib]` depends.)

- [ ] **Step 4: commit.** `git add src/Evals/Grade.hs src/Evals/Execute/OpenAI.hs test/GradeSpec.hs && git commit -m "$(printf 'feat(grade): providerFrom + openaiCfgFromParams config helpers\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"`

---

### Task 2: rename to `Evals.Grade.Live` + provider dispatch

**Files:** rename `src/Evals/Grade/Anthropic.hs` → `src/Evals/Grade/Live.hs`; `app/Main.hs`, `test/GradeSpec.hs` (importers).

- [ ] **Step 1: rename + rewrite the module.** `git mv src/Evals/Grade/Anthropic.hs src/Evals/Grade/Live.hs`. Rewrite its header + body to:
```haskell
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The live grading edge: builds a crucible LLM config from the grader's
-- config jsonb and runs crucible's eval scorer / judge against the real API.
-- The @provider@ config key selects Anthropic (default) or OpenAI per grader.
module Evals.Grade.Live
  ( LiveKeys (..)
  , gradeCfg
  , openaiCfg
  , liveGradeRunner
  , liveCriterionJudge
  ) where

import Control.Exception (try)
import Data.Aeson (Value)
import qualified Data.Aeson.Types as AT
import Data.Text (Text)
import qualified Data.Text as T
import Effectful (runEff)

import qualified Crucible.Embed as Embed
import qualified Crucible.Eval as Eval
import qualified Crucible.Eval.Judge as Judge
import Crucible.LLM.Anthropic (AnthropicConfig, AnthropicError)
import qualified Crucible.LLM.Anthropic as Anthropic
import Crucible.LLM.OpenAI (OpenAIConfig, OpenAIError)
import qualified Crucible.LLM.OpenAI as OpenAI
import Manifest (Aeson (..))

import Evals.Execute (ExecError (..))
import Evals.Execute.Anthropic (cfgFromParams)
import Evals.Execute.OpenAI (openaiCfgFromParams)
import Evals.Grade (CriterionJudge, CriterionVerdict (..), GradeRunner, providerFrom, renderCriterion, votesFrom)
import Evals.Schema ()

-- | API keys for the live edge: Anthropic always; OpenAI only when a grader
-- selects it.
data LiveKeys = LiveKeys { anthropic :: Text, openai :: Maybe Text }

-- | The grader's Anthropic config (optional @model@ + shared knobs).
gradeCfg :: Text -> Value -> AnthropicConfig
gradeCfg key cfgV = cfgFromParams key (AT.parseMaybe (AT.withObject "config" (AT..: "model")) cfgV) cfgV

-- | The grader's OpenAI config (optional @model@ + shared knobs).
openaiCfg :: Text -> Value -> OpenAIConfig
openaiCfg key cfgV = openaiCfgFromParams key (AT.parseMaybe (AT.withObject "config" (AT..: "model")) cfgV) cfgV

-- | One crucible 'Eval.scoreN' per call, dispatched to the grader's provider.
liveGradeRunner :: LiveKeys -> GradeRunner
liveGradeRunner keys gv expectation rendered =
  let act = Embed.none (Eval.scoreN (votesFrom cfgV) id expectation rendered)
      ok  = pure . Right
      bad :: Show e => e -> IO (Either ExecError Eval.Score)
      bad e = pure (Left (LlmError (T.pack (show e))))
  in case providerFrom cfgV of
       "openai" -> case keys.openai of
         Nothing -> pure (Left (LlmError "grader provider is openai but OPENAI_API_KEY is not set"))
         Just k  -> try (runEff (OpenAI.run (openaiCfg k cfgV) act)) >>= either (bad @OpenAIError) ok
       _        -> try (runEff (Anthropic.run (gradeCfg keys.anthropic cfgV) act)) >>= either (bad @AnthropicError) ok
  where Aeson cfgV = gv.config

-- | One crucible 'Judge.vote' per criterion, dispatched to the grader's provider.
liveCriterionJudge :: LiveKeys -> CriterionJudge
liveCriterionJudge keys gv transcriptTxt c =
  let act = Judge.vote True (Judge.defaultJudgeOpts { Judge.votes = votesFrom cfgV }) (renderCriterion c) transcriptTxt
      decode = \case
        Right (Judge.Decided p w _ _ _) -> pure (Right CriterionVerdict { met = p, explanation = w })
        Right (Judge.AllErrored m)      -> pure (Left (LlmError ("judge error: " <> m)))
        Right (Judge.AllAbstained m)    -> pure (Left (LlmError ("judge abstained: " <> m)))
        Left e                          -> pure (Left (LlmError (T.pack (show e))))
  in case providerFrom cfgV of
       "openai" -> case keys.openai of
         Nothing -> pure (Left (LlmError "grader provider is openai but OPENAI_API_KEY is not set"))
         Just k  -> (try (runEff (OpenAI.run (openaiCfg k cfgV) act)) :: IO (Either OpenAIError Judge.VoteOutcome)) >>= decode
       _        -> (try (runEff (Anthropic.run (gradeCfg keys.anthropic cfgV) act)) :: IO (Either AnthropicError Judge.VoteOutcome)) >>= decode
  where Aeson cfgV = gv.config
```
(If the `bad @OpenAIError` / `either` shape or the `decode`'s `Left e` polymorphism fights the typechecker, fall back to explicit `\case` with `Left (e :: OpenAIError)` per branch — the two branches having different error types is the only subtlety. The crucible action `act` is intentionally shared; both interpreters accept `Eff (LLM:es) a`.)

- [ ] **Step 2: update importers.** In `app/Main.hs`, change `import Evals.Grade.Anthropic (liveCriterionJudge, liveGradeRunner)` → `import Evals.Grade.Live (LiveKeys (..), liveCriterionJudge, liveGradeRunner)`. In `test/GradeSpec.hs`, change `import Evals.Grade.Anthropic (gradeCfg)` → `import Evals.Grade.Live (gradeCfg)`. (app/Main.hs call sites are fixed in Task 3; for now Task 2's build will fail at the call sites — do Task 2 + Task 3 edits together before building, OR temporarily keep the build green by deferring the app/Main.hs call-site change. Simplest: do Step 2's import rename AND Task 3's call-site changes, then build once.)

- [ ] **Step 3:** proceed to Task 3 before building (the `app/Main.hs` call sites need the `LiveKeys` plumbing to compile). After Task 3: `nix develop -c zinc build 2>&1 | tail -5` and `nix develop -c zinc test 2>&1 | tail -8` green. Commit happens in Task 3.

---

### Task 3: CLI both-keys plumbing + README + push

**Files:** `app/Main.hs`, `README.md`.

- [ ] **Step 1: `liveKeys` helper.** In `app/Main.hs`, add `import System.Environment (lookupEnv)` if not present (it likely already imports `getArgs`/`lookupEnv`). Add:
```haskell
liveKeys :: IO LiveKeys
liveKeys = do
  a <- requireEnv "ANTHROPIC_API_KEY"
  o <- lookupEnv "OPENAI_API_KEY"
  pure (LiveKeys { anthropic = T.pack a, openai = T.pack <$> o })
```

- [ ] **Step 2: `score` arm.** Replace the `score` arm's `key <- requireEnv "ANTHROPIC_API_KEY"` + the `scoreRun … (liveGradeRunner (T.pack key)) (liveCriterionJudge (T.pack key)) …` with:
```haskell
        ks   <- liveKeys
        conc <- concurrencyFrom flags
        withEnvPool $ \pool -> do
          o <- scoreRun pool conc (liveGradeRunner ks) (liveCriterionJudge ks) (RunId rid) gvs
          ... (unchanged putStrLn summary)
```
(Drop the now-unused `key <-` binding.)

- [ ] **Step 3: `metaeval report` live branch.** Replace `"live" -> Live . liveCriterionJudge . T.pack <$> requireEnv "ANTHROPIC_API_KEY"` with `"live" -> Live . liveCriterionJudge <$> liveKeys`.

- [ ] **Step 4: build + tests.** `nix develop -c zinc build 2>&1 | tail -5` (links — the rename + dispatch + CLI all resolve) and `nix develop -c zinc test 2>&1 | tail -8` (all specs green; GradeSpec's provider/openaiCfg tests pass; the `gradeCfg` import now from `Evals.Grade.Live`).

- [ ] **Step 5: README.** In the scorer/grader-config docs, add: a grader's config jsonb may set `"provider": "openai"` (default `"anthropic"`) to route judging through OpenAI; set `OPENAI_API_KEY` when any grader uses it (`ANTHROPIC_API_KEY` is always required). Model/knobs (`model`/`max_tokens`/`timeout`/`retries`/`votes`) apply to either provider.

- [ ] **Step 6: commit + push.** `git add -A && git commit -m "$(printf 'feat(grade): OpenAI provider knob — per-grader Anthropic|OpenAI judge dispatch\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')" && git push`

---

## Self-Review
- Spec §1 (`providerFrom`, `openaiCfgFromParams`) → Task 1; §2 (rename `Evals.Grade.Live`, `LiveKeys`, dispatch, shared action) → Task 2; §3 (CLI both keys) → Task 3; §4 testing (pure provider/openaiCfg; live edge-only) → Tasks 1–3; §5 out-of-scope (no execution OpenAI, no live test) absent.
- Type consistency: `providerFrom :: Value -> Text`; `openaiCfgFromParams :: Text -> Maybe Text -> Value -> OpenAIConfig`; `LiveKeys {anthropic :: Text, openai :: Maybe Text}`; `liveGradeRunner :: LiveKeys -> GradeRunner`; `liveCriterionJudge :: LiveKeys -> CriterionJudge` — call sites in `app/Main.hs` pass `ks :: LiveKeys`. The shared `act` is `Eff` polymorphic, accepted by both `Anthropic.run`/`OpenAI.run`.
- KNOWN RISK: the two-error-type dispatch (`AnthropicError` vs `OpenAIError`) in one function may need per-branch `ScopedTypeVariables` annotations; the plan flags the fallback to explicit `\case` with typed `Left (e :: …)`. The live OpenAI call is NOT verified this slice (flagged).
