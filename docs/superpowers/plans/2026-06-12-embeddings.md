# Embeddings and Similarity Evals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An `Embed` dynamic effect with scripted/OpenAI/Voyage interpreters, pure `cosine` + group `consistency` helpers, and a per-case `SimilarTo` expectation (accepting the breaking `Embed :> es` ripple through the scoring functions).

**Architecture:** Spec at `docs/superpowers/specs/2026-06-12-embeddings-design.md` (tracker `crucible-d4w`). New `Crucible.Embed` (effect, scripted, none, vector math) and `Crucible.LLM.Voyage` (new provider); `Crucible.LLM.OpenAI` gains `runEmbed` + an `embedModel` config field; `Crucible.Eval` gains `SimilarTo` and the constraint change. **Ripple wider than the spec recorded:** `Crucible.Skill.testSkill` calls `runEval` and `Crucible.Skill.Improve.improveSkill` calls `testSkill`, so both gain `Embed :> es` too; `calibrate` uses `vote` directly and is untouched. Task 3 amends the spec.

**Tech Stack:** Haskell GHC 9.12.2, effectful, http-client-tls, retry, aeson. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). Exit 137 = GHC iserv flake, retry once; second 137 = BLOCKED. Judge success by exit status or the pass line, never a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/embeddings` from master; work in place, no worktrees.
- House style: DuplicateRecordFields, NoFieldSelectors, OverloadedRecordDot, prefix-free fields. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Read first: `src/Crucible/LLM.hs` (the effect/scripted pattern to mirror), `src/Crucible/LLM/OpenAI.hs` (config, manager, `withOpenAIRetry`, `postCompletions`, pure request/extract functions, error type — the model for both new interpreters; note `completionsRequest` hardcodes the URL, there is NO baseUrl field).
- The suite passes with 253 checks.
- API keys live in `.env` (gitignored): ANTHROPIC_API_KEY, OPENAI_API_KEY, possibly VOYAGE_API_KEY. NEVER print, echo, or cat `.env` or any key value.

---

### Task 1: `Crucible.Embed` (effect + scripted + vector math) + tests

**Files:**
- Create: `src/Crucible/Embed.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: create `src/Crucible/Embed.hs`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | The embedding capability as a dynamic effect, plus the pure vector
-- math evals build on. Interpret with 'runEmbedScripted' in tests,
-- @OpenAI.runEmbed@ or @Voyage.runEmbed@ live, or 'none' for programs
-- that never embed (the one-line migration for scoreM\/runEval callers
-- with no 'Crucible.Eval.SimilarTo' cases).
module Crucible.Embed
  ( Embed (..)
  , embed
  , runEmbedScripted
  , none
  , cosine
  , consistency
  ) where

import Data.List (tails)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (evalState, get, put)

-- | The embedding capability: one text in, one vector out.
data Embed :: Effect where
  EmbedText :: Text -> Embed m [Double]
type instance DispatchOf Embed = Dynamic

embed :: (Embed :> es) => Text -> Eff es [Double]
embed t = send (EmbedText t)

-- | Interpret Embed by popping canned vectors (tests). Mirrors
-- 'Crucible.LLM.runLLMScripted', including its dry-script behaviour:
-- an exhausted script yields @[]@.
runEmbedScripted :: [[Double]] -> Eff (Embed : es) a -> Eff es a
runEmbedScripted vecs = reinterpret (evalState vecs) $ \_ -> \case
  EmbedText _ -> do
    vs <- get
    case vs of
      (x : xs) -> put xs >> pure x
      []       -> pure []

-- | Discharge Embed for programs that never embed: errors with a clear
-- message on first use. Wrap scoreM\/runEval programs with this when the
-- dataset has no 'Crucible.Eval.SimilarTo' cases.
none :: Eff (Embed : es) a -> Eff es a
none = interpret $ \_ -> \case
  EmbedText _ ->
    error
      "Crucible.Embed.none: this program embeds text; interpret Embed with \
      \OpenAI.runEmbed, Voyage.runEmbed, or runEmbedScripted"

-- | Pure cosine similarity; 0 when either vector is all zeros.
cosine :: [Double] -> [Double] -> Double
cosine xs ys
  | nx == 0 || ny == 0 = 0
  | otherwise          = dot / (nx * ny)
  where
    dot = sum (zipWith (*) xs ys)
    nx  = sqrt (sum [x * x | x <- xs])
    ny  = sqrt (sum [y * y | y <- ys])

-- | Mean pairwise cosine over a paraphrase group's outputs; groups of
-- zero or one text score 1.0. The group-shaped consistency eval:
-- compares outputs across runs, deliberately outside
-- 'Crucible.Eval.Expectation' (which grades one output).
consistency :: (Embed :> es) => [Text] -> Eff es Double
consistency ts
  | length ts <= 1 = pure 1.0
  | otherwise = do
      vs <- mapM embed ts
      let pairs = [cosine a b | (a : rest) <- tails vs, b <- rest]
      pure (sum pairs / fromIntegral (length pairs))
```

- [ ] **Step 2: tests in `test/Spec.hs`.** Imports: `import Crucible.Embed (embed, runEmbedScripted, cosine, consistency)` and `import qualified Crucible.Embed as Embed` (the qualified one is used from Task 3 onward; add both now). Add after the ratePrompt check block's neighbours (end of list):

```haskell
  -- crucible-d4w: embeddings (pure math + scripted interpreter)
  , check "cosine: orthogonal and zero-vector cases are 0"
      (0.0, 0.0) (cosine [1, 0] [0, 1], cosine [0, 0] [1, 1])
  , check "cosine: identical is 1; hand value 1/sqrt 2"
      (True, True)
      ( abs (cosine [1, 2] [1, 2] - 1.0) < 1e-9
      , abs (cosine [1, 0] [1, 1] - 1 / sqrt 2) < 1e-9 )
  , check "consistency: mean pairwise cosine over a group"
      True
      (let r = runPureEff (runEmbedScripted [[1, 0], [0, 1], [1, 1]]
                 (consistency ["a", "b", "c"]))
       in abs (r - sqrt 2 / 3) < 1e-9)
  , check "consistency: empty and singleton groups score 1.0"
      (1.0, 1.0)
      ( runPureEff (runEmbedScripted [] (consistency []))
      , runPureEff (runEmbedScripted [] (consistency ["only"])) )
  , check "embed: a dry script yields the empty vector"
      ([] :: [Double])
      (runPureEff (runEmbedScripted [] (embed "x")))
```

Derivation for the consistency check: vectors a=[1,0], b=[0,1], c=[1,1]; cosine(a,b)=0, cosine(a,c)=1/sqrt 2, cosine(b,c)=1/sqrt 2; mean = (2/sqrt 2)/3 = sqrt 2/3. If a value differs, the CODE is wrong; never weaken an expectation.

- [ ] **Step 3: build + suite.** Build exit 0; `1 test suite(s) passed`, 258 ok (253 + 5).

- [ ] **Step 4: commit.**

```bash
git add src/Crucible/Embed.hs test/Spec.hs
git commit -m "$(printf 'feat(embed): Embed effect, scripted interpreter, cosine + consistency\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: OpenAI `runEmbed` + `Crucible.LLM.Voyage` + pure wire tests

**Files:**
- Modify: `src/Crucible/LLM/OpenAI.hs`
- Create: `src/Crucible/LLM/Voyage.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: OpenAI.** Add `embedModel :: Text` to `OpenAIConfig` (after `model`), set `embedModel = "text-embedding-3-small"` in `defaultOpenAIConfig`. Add to the export list: `runEmbed`, `embedRequestJson`, `extractEmbedding`. Add `import Crucible.Embed (Embed (..))`. Then (placed near the other request builders):

```haskell
-- | The embeddings request body: the configured embedding model and one
-- input text.
embedRequestJson :: OpenAIConfig -> Text -> Value
embedRequestJson cfg input =
  A.object ["model" .= cfg.embedModel, "input" .= input]

-- | Pull @data[0].embedding@ out of an embeddings response.
extractEmbedding :: Text -> Either String [Double]
extractEmbedding t = do
  v <- A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 t))
  AT.parseEither
    (A.withObject "resp" $ \o -> do
        ds <- o .: "data"
        case ds of
          (x : _) -> A.withObject "datum" (.: "embedding") x
          []      -> fail "empty data array")
    v

-- | POST a JSON body to @\/v1\/embeddings@ with the shared headers and
-- retry policy (mirrors 'postCompletions').
postEmbeddings :: OpenAIConfig -> Manager -> Value -> IO Text
postEmbeddings cfg mgr bodyJson =
  withOpenAIRetry cfg $
    handle (\(e :: HttpException) -> throwIO (OpenAIHttpError e)) $ do
      base <- parseRequest "https://api.openai.com/v1/embeddings"
      let req = base
            { method = "POST"
            , requestHeaders =
                [ ("authorization", "Bearer " <> TE.encodeUtf8 cfg.apiKey)
                , ("content-type", "application/json")
                ]
            , requestBody = RequestBodyLBS (A.encode bodyJson)
            }
      resp <- httpLbs req mgr
      let body = TE.decodeUtf8Lenient (LBS.toStrict (responseBody resp))
          code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then pure body
        else throwIO (OpenAIStatusError code body)

-- | Interpret 'Embed' against the live OpenAI embeddings API. One shared
-- TLS manager; each 'EmbedText' is one @POST \/v1\/embeddings@ with
-- timeout + retry. Failures throw 'OpenAIError'. Use as @OpenAI.runEmbed@.
runEmbed :: (IOE :> es) => OpenAIConfig -> Eff (Embed : es) a -> Eff es a
runEmbed cfg action = do
  mgr <- liftIO (newOpenAIManager cfg)
  interpret
    (\_ (EmbedText t) -> liftIO $ do
        body <- postEmbeddings cfg mgr (embedRequestJson cfg t)
        either (\_ -> throwIO (OpenAINoContent body)) pure (extractEmbedding body))
    action
```

- [ ] **Step 2: create `src/Crucible/LLM/Voyage.hs`** (mirrors the OpenAI module's structure; embeddings only):

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- | The live Voyage AI interpreter for the 'Embed' effect. Voyage is an
-- embeddings-only provider (Anthropic has no embeddings endpoint and
-- points customers here). Used qualified: @Voyage.runEmbed@.
module Crucible.LLM.Voyage
  ( VoyageConfig (..)
  , defaultVoyageConfig
  , newVoyageManager
  , VoyageError (..)
  , isRetryable
  , embedRequestJson
  , extractEmbedding
  , runEmbed
  ) where

import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as LBS

import Effectful
import Effectful.Dispatch.Dynamic (interpret)

import Control.Exception (Exception, handle, throwIO)
import Control.Monad.Catch (Handler (Handler))
import Control.Retry (capDelay, fullJitterBackoff, limitRetries, recovering)
import Network.HTTP.Client
  ( HttpException
  , Manager
  , ManagerSettings (managerResponseTimeout)
  , RequestBody (RequestBodyLBS)
  , httpLbs
  , method
  , newManager
  , parseRequest
  , requestBody
  , requestHeaders
  , responseBody
  , responseStatus
  , responseTimeoutMicro
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

import qualified Data.Aeson as A
import Data.Aeson (Value, (.=), (.:))
import qualified Data.Aeson.Types as AT

import Crucible.Embed (Embed (..))

-- | A typed live-path failure, mirroring the other providers' error types.
data VoyageError
  = VoyageHttpError   HttpException
  | VoyageStatusError Int Text
  | VoyageNoContent   Text
  deriving (Show)

instance Exception VoyageError

-- | Whether a failure is worth retrying: network/timeout errors and HTTP
-- 429 / 5xx are transient; other 4xx and a content-shape failure are
-- permanent.
isRetryable :: VoyageError -> Bool
isRetryable (VoyageHttpError _)     = True
isRetryable (VoyageStatusError s _) = s == 429 || s >= 500
isRetryable (VoyageNoContent _)     = False

-- | What the live interpreter needs: an API key, a model id, and knobs
-- for timeout + retry behaviour.
data VoyageConfig = VoyageConfig
  { apiKey          :: Text
  , model           :: Text
  , timeoutSecs     :: Int
  , maxRetries      :: Int
  , baseDelayMicros :: Int
  }
  deriving (Eq, Show)

-- | A config with sensible defaults (voyage-3.5-lite, 60s timeout,
-- 3 retries, 0.5s backoff base); supply the API key.
defaultVoyageConfig :: Text -> VoyageConfig
defaultVoyageConfig key =
  VoyageConfig
    { apiKey = key
    , model = "voyage-3.5-lite"
    , timeoutSecs = 60
    , maxRetries = 3
    , baseDelayMicros = 500000
    }

maxBackoffMicros :: Int
maxBackoffMicros = 30000000

-- | One TLS 'Manager' configured with the request timeout.
newVoyageManager :: VoyageConfig -> IO Manager
newVoyageManager cfg =
  newManager
    tlsManagerSettings
      { managerResponseTimeout = responseTimeoutMicro (cfg.timeoutSecs * 1000000) }

-- | The embeddings request body. Voyage takes @input@ as an ARRAY of
-- texts; crucible sends one per call.
embedRequestJson :: VoyageConfig -> Text -> Value
embedRequestJson cfg input =
  A.object ["model" .= cfg.model, "input" .= [input]]

-- | Pull @data[0].embedding@ out of an embeddings response (the same
-- response shape as OpenAI's embeddings endpoint).
extractEmbedding :: Text -> Either String [Double]
extractEmbedding t = do
  v <- A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 t))
  AT.parseEither
    (A.withObject "resp" $ \o -> do
        ds <- o .: "data"
        case ds of
          (x : _) -> A.withObject "datum" (.: "embedding") x
          []      -> fail "empty data array")
    v

-- | POST to the Voyage embeddings endpoint with full-jitter retry on
-- retryable failures.
postEmbeddings :: VoyageConfig -> Manager -> Value -> IO Text
postEmbeddings cfg mgr bodyJson =
  recovering
    (capDelay maxBackoffMicros (fullJitterBackoff cfg.baseDelayMicros)
       <> limitRetries cfg.maxRetries)
    [ \_ -> Handler (\(e :: VoyageError) -> pure (isRetryable e)) ]
    (\_ ->
      handle (\(e :: HttpException) -> throwIO (VoyageHttpError e)) $ do
        base <- parseRequest "https://api.voyageai.com/v1/embeddings"
        let req = base
              { method = "POST"
              , requestHeaders =
                  [ ("authorization", "Bearer " <> TE.encodeUtf8 cfg.apiKey)
                  , ("content-type", "application/json")
                  ]
              , requestBody = RequestBodyLBS (A.encode bodyJson)
              }
        resp <- httpLbs req mgr
        let body = TE.decodeUtf8Lenient (LBS.toStrict (responseBody resp))
            code = statusCode (responseStatus resp)
        if code >= 200 && code < 300
          then pure body
          else throwIO (VoyageStatusError code body))

-- | Interpret 'Embed' against the live Voyage embeddings API. One shared
-- TLS manager; each 'EmbedText' is one POST with timeout + retry.
-- Failures throw 'VoyageError'. Use as @Voyage.runEmbed@.
runEmbed :: (IOE :> es) => VoyageConfig -> Eff (Embed : es) a -> Eff es a
runEmbed cfg action = do
  mgr <- liftIO (newVoyageManager cfg)
  interpret
    (\_ (EmbedText t) -> liftIO $ do
        body <- postEmbeddings cfg mgr (embedRequestJson cfg t)
        either (\_ -> throwIO (VoyageNoContent body)) pure (extractEmbedding body))
    action
```

Note: the spec lists VoyageConfig as {apiKey, model, baseUrl}; as built it carries the house timeout/retry knobs instead of baseUrl (the URL is hardcoded exactly as OpenAI's is). This is the established provider pattern; report it as a deviation so the controller can amend the spec.

- [ ] **Step 3: pure wire tests in `test/Spec.hs`.** Imports: `import qualified Crucible.LLM.Voyage as Voyage` (OpenAI is already imported qualified; its new exports come through). Add after the Task 1 embed checks (note: `embedRequestJson`/`extractEmbedding` exist in BOTH provider modules; always use them qualified):

```haskell
  -- crucible-d4w: embedding wire formats (pure)
  , check "openai embed: request body pins model and input"
      (A.object ["model" A..= ("text-embedding-3-small" :: Text), "input" A..= ("hello" :: Text)])
      (OpenAI.embedRequestJson (defaultOpenAIConfig "k") "hello")
  , check "openai embed: response decode pulls data[0].embedding"
      (Right [0.1, 0.2 :: Double])
      (OpenAI.extractEmbedding "{\"data\":[{\"embedding\":[0.1,0.2]}]}")
  , check "voyage embed: request body wraps input in an array"
      (A.object ["model" A..= ("voyage-3.5-lite" :: Text), "input" A..= (["hello"] :: [Text])])
      (Voyage.embedRequestJson (defaultVoyageConfig "k") "hello")
  , check "voyage embed: response decode + junk rejection"
      (Right [1.5 :: Double], True)
      ( Voyage.extractEmbedding "{\"data\":[{\"embedding\":[1.5]}]}"
      , case Voyage.extractEmbedding "junk" of Left _ -> True; Right _ -> False )
```

Check how Spec.hs imports aeson (it likely has `import qualified Data.Aeson as A` already; the `A..=` form needs it). Adapt the operators to the file's existing aeson import style and report the adaptation.

- [ ] **Step 4: build + suite.** Build exit 0 (zinc auto-discovers Voyage.hs); `1 test suite(s) passed`, 262 ok (258 + 4).

- [ ] **Step 5: commit.**

```bash
git add src/Crucible/LLM/OpenAI.hs src/Crucible/LLM/Voyage.hs test/Spec.hs
git commit -m "$(printf 'feat(embed): OpenAI and Voyage live interpreters for the Embed effect\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: `SimilarTo` + the constraint ripple

**Files:**
- Modify: `src/Crucible/Eval.hs`
- Modify: `src/Crucible/Skill.hs` (signature only)
- Modify: `src/Crucible/Skill/Improve.hs` (signature only)
- Modify: `test/Spec.hs`
- Modify: `docs/superpowers/specs/2026-06-12-embeddings-design.md` (one amendment)

- [ ] **Step 1: Eval.hs.** Add `import Crucible.Embed (Embed, embed, cosine)`. Append to `Expectation`:

```haskell
  | SimilarTo Double Text  -- ^ pass threshold, reference text: embeds both
                           --   the reference and the output, scoring cosine
                           --   similarity clamped to [0,1], passing at
                           --   value >= threshold. Needs an Embed
                           --   interpreter at the edge; 'Crucible.Embed.none'
                           --   serves programs without similarity cases.
```

`scoreWith` gains the constraint and the arm (reference embedded FIRST, then the rendered output):

```haskell
scoreWith :: (Eq a, LLM :> es, Embed :> es) => JudgeOpts -> (a -> Text) -> Expectation a -> a -> Eff es Score
...
  SimilarTo _ ref -> do
    rv <- embed ref
    ov <- embed (render actual)
    let v = min 1.0 (max 0.0 (cosine rv ov))
    pure (score v ("cosine = " <> T.pack (show v)))
```

`passes` gains `passes (SimilarTo t _) v = v >= t`. Propagate `Embed :> es` to the signatures of `scoreM`, `scoreN`, `runEvalWith`, `runEval`, `runEvalN` (definitions unchanged). `judgeWith`/`judge`/`judgeN`/`groundingCheck` keep their current constraints (they do not dispatch expectations).

- [ ] **Step 2: Skill ripple.** In `src/Crucible/Skill.hs`: `testSkill :: (Eq o, LLM :> es, Embed :> es) => ...` (import `Crucible.Embed (Embed)`). In `src/Crucible/Skill/Improve.hs`: `improveSkill` gains `Embed :> es` the same way (read its current signature and add the constraint; import `Crucible.Embed (Embed)`). No body changes in either.

- [ ] **Step 3: the mechanical sweep.** Build; the compiler lists every call site needing Embed. In `test/Spec.hs`, wrap the inner program with `Embed.none`: `runLLMScripted rs (P)` becomes `runLLMScripted rs (Embed.none (P))` at every site involving `runEval`/`runEvalN`/`runEvalWith`/`scoreM`/`scoreN`/`testSkill`/`improveSkill` (roughly 35 sites; `calibrate`/`judge*` sites need nothing). The entire pre-existing battery passing under `Embed.none` IS the spec's "scores exactly as before" regression check; no separate check is needed (report this as the covered-by-construction note). Leave `app/Main.hs` alone in this task; Task 4 owns it (the build of the demo executable may fail until then — judge this task by `zinc test`, and if zinc insists on building the executable first, apply Task 4 Step 1's three `Embed.none` wrappers to Main.hs now, report it, and Task 4 will keep them).

- [ ] **Step 4: new checks** (after the wire-format checks):

```haskell
  -- crucible-d4w: SimilarTo expectation
  , check "similarTo: identical embeddings score 1.0, no votes"
      (1.0, Nothing)
      (let s = runPureEff (runLLMScripted [] (runEmbedScripted [[1, 0], [1, 0]]
                 (scoreM id (SimilarTo 0.8 "ref") ("out" :: Text))))
       in (s.value, s.votes))
  , check "similarTo: hand cosine lands in value"
      True
      (let s = runPureEff (runLLMScripted [] (runEmbedScripted [[1, 0], [1, 1]]
                 (scoreM id (SimilarTo 0.8 "ref") ("out" :: Text))))
       in abs (s.value - 1 / sqrt 2) < 1e-9)
  , check "similarTo: negative cosine clamps to 0"
      0.0
      ((runPureEff (runLLMScripted [] (runEmbedScripted [[1, 0], [-1, 0]]
          (scoreM id (SimilarTo 0.5 "ref") ("out" :: Text))))).value)
  , check "similarTo: threshold gates passRate in a mixed dataset"
      (0.5, 0.5)
      (let rep = runPureEff (runLLMScripted [] (runEmbedScripted [[1, 0], [0, 1]]
                   (runEval id pure
                      [ Case ("x" :: Text) "exact" (Exactly "x")
                      , Case "y" "orthogonal" (SimilarTo 0.8 "ref") ])))
       in (rep.passRate, rep.meanScore))
  , do r <- try (evaluate (runPureEff (runLLMScripted [] (Embed.none
              (scoreM id (SimilarTo 0.8 "ref") ("out" :: Text))))))
       check "embed: none errors clearly when a program embeds"
         True
         (case r of
            Left (e :: SomeException) -> T.isInfixOf "Crucible.Embed.none" (T.pack (show e))
            Right s -> s.value < 0)  -- unreachable; forces the Score
```

Notes: the scripted vector order is (reference, output) because scoreWith embeds the reference first. The mixed check: Exactly passes (1.0), orthogonal cosine 0 fails at 0.8; passRate 0.5, mean (1.0 + 0.0)/2 = 0.5. `evaluate` comes from `Control.Exception`; check Spec.hs's existing exception imports and extend minimally. If the error does not surface through `evaluate` (laziness), force `s.value` instead (`evaluate (... ).value`) and report.

- [ ] **Step 5: amend the spec.** In `docs/superpowers/specs/2026-06-12-embeddings-design.md`, section 4, extend the breaking-change paragraph: after "rippling to `scoreM`, `scoreN`, `runEval`, `runEvalN`, `runEvalWith`." add "(As built: also `Crucible.Skill.testSkill` and `Crucible.Skill.Improve.improveSkill`, which call `runEval` internally; found during planning.)"

- [ ] **Step 6: build + suite.** `1 test suite(s) passed`, 267 ok (262 + 5).

- [ ] **Step 7: commit.**

```bash
git add src/Crucible/Eval.hs src/Crucible/Skill.hs src/Crucible/Skill/Improve.hs test/Spec.hs docs/superpowers/specs/2026-06-12-embeddings-design.md
git commit -m "$(printf 'feat(eval): SimilarTo expectation; Embed constraint through the scoring path\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 4: demo + live smoke + docs

**Files:**
- Modify: `app/Main.hs`
- Modify: `docs/evals.md`
- Modify: `docs/live-interpreter.md`

- [ ] **Step 1: Main.hs migration + demo.** Imports: `import Crucible.Embed (embed)`, `import qualified Crucible.Embed as Embed`, `import qualified Crucible.LLM.Voyage as Voyage`; `SimilarTo` arrives via the existing `Expectation (..)` import. Three existing calls gain `Embed.none` (unless Task 3 already applied them): the `runEvalN 3` eval block, the `improveSkill` call, and the `scoreM ... Scale` politeness call — wrap the program inside the `Anthropic.run cfg (...)`, e.g. `Anthropic.run cfg (Embed.none (runEvalN 3 ...))`. Then INSIDE the OpenAI-key-gated block (after the fallback demo), add:

```haskell
          -- Embeddings: consistency across paraphrases + a SimilarTo case.
          cons <- runEff (OpenAI.runEmbed ocfg (Embed.consistency
            [ "The return window is 30 days."
            , "You have thirty days to return an item." ]))
          TIO.putStrLn ("consistency: " <> T.pack (show cons))
          simRep <- runEff (OpenAI.runEmbed ocfg (Anthropic.run cfg (runEval id pure
            [ Case ("The capital of France is Paris." :: T.Text) "similar-capital"
                (SimilarTo 0.6 "Paris is France's capital city.") ])))
          TIO.putStrLn (renderReport simRep)
```

(The `Anthropic.run cfg` discharges the LLM constraint; a SimilarTo-only dataset makes no LLM calls, so it costs nothing.) After the whole OpenAI `case` block (same indentation level as the `mOpenKey <- lookupEnv ...` line), add:

```haskell
      mVoyKey <- lookupEnv "VOYAGE_API_KEY"
      case mVoyKey of
        Nothing -> TIO.putStrLn "VOYAGE_API_KEY not set; skipping Voyage demo"
        Just vkey -> do
          vec <- runEff (Voyage.runEmbed (defaultVoyageConfig (T.pack vkey))
                   (embed "crucible embeds with Voyage"))
          TIO.putStrLn ("voyage: embedded to " <> T.pack (show (length vec)) <> " dims")
```

(`defaultVoyageConfig` via the qualified import: `Voyage.defaultVoyageConfig`. Adapt to the qualified form and report.)

- [ ] **Step 2: build + live smoke.**

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 420 .zinc/build/crucible-anthropic'
```

Expected: all existing output, plus `consistency: 0.x` (paraphrases should land well above 0.5), the `similar-capital: ...` report line scoring high and passing, and either the `voyage: embedded to N dims` line or the clean skip message. If Voyage returns a 4xx naming an unknown model, correct the `defaultVoyageConfig` model from the API's error message (NEVER print the key) and report the final model id.

- [ ] **Step 3: docs.** Both files; read each first and match voice. House style STRICT: no emdashes/endashes (`grep -n $'—\|–' docs/evals.md docs/live-interpreter.md` empty), no hype, no "manifest" mentions.

`docs/evals.md`:
- Top-of-page `Expectation` listing gains `| SimilarTo Double Text   -- pass threshold, reference: embedded cosine similarity`.
- The "Scalar metrics and ordinal scales" choosing ladder gains a `SimilarTo` rung (semantic closeness to a reference, embedded, deterministic given the embedder).
- A short `### Semantic similarity` subsection in that section: `SimilarTo threshold reference` semantics (two embed calls per case, cosine clamped to [0,1], passes at the threshold); the constraint note (`runEval` and friends now need an `Embed` interpreter at the edge; `Embed.none` is the one-liner for datasets without similarity cases); the group-vs-per-case distinction with a `consistency` example (paraphrase groups compare outputs across runs and live outside `Expectation`).
- The Limits paragraph: drop "Embedding cosine similarity is tracked separately." (it shipped); keep the rest.

`docs/live-interpreter.md`: a `## Embeddings` section after the fallback section: the `Embed` effect and `embed`; `OpenAI.runEmbed` with the `embedModel` config field and its default; `Voyage.runEmbed` with `defaultVoyageConfig` and the `VOYAGE_API_KEY` convention; `runEmbedScripted` for tests and `Embed.none` for programs that never embed; the limits (no usage variants, no cassettes, no fallback chains for Embed yet).

- [ ] **Step 4: commit.**

```bash
git add app/Main.hs docs/evals.md docs/live-interpreter.md
git commit -m "$(printf 'docs(site)+demo: embeddings live (consistency, SimilarTo, Voyage)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 5: merge + publish + close + handoff

**Files:** none (bd memory only).

- [ ] **Step 1: full suite.** `... zinc test` shows `1 test suite(s) passed`, 267 ok.
- [ ] **Step 2: merge + push.** Via `superpowers:finishing-a-development-branch`; after merge: suite on master, `git push`, Pages build reaches `built`.
- [ ] **Step 3: update the manifest-evals memory** (breaking change, downstream):

```bash
bd remember --key manifest-evals-code-garethstokes-manifest-evals-is-the "manifest-evals (~/code/garethstokes/manifest-evals) is the bridge project between crucible and manifest: depends on both via pinned git revs in zinc.toml. Its crucible surface: Crucible.LLM (Message/Role/complete), Crucible.Usage, Crucible.LLM.Anthropic (config/errors), scoreN from Crucible.Eval. BREAKING at next pin bump: scoreN (and runEval/scoreM family) now requires Embed :> es; wrap the program with Crucible.Embed.none (one line) unless it uses SimilarTo. Bump with 'zinc update crucible' (targeted; full 'zinc update' fails on the miso spike's assoc/these registry gap), then 'zinc build .' + 'zinc test' (spins up its own postgres). Crucible breaking changes ripple here first."
```

- [ ] **Step 4: close the bead.**

```bash
bd close crucible-d4w --reason="Shipped: Embed effect (scripted/none/cosine/consistency), OpenAI runEmbed + embedModel config, new Crucible.LLM.Voyage provider, SimilarTo expectation with Embed constraint through the scoring path (testSkill/improveSkill included), 14 hermetic tests, live consistency + SimilarTo + Voyage proofs, evals.md and live-interpreter.md sections."
```

---

## Self-Review

**1. Spec coverage:** Embed effect + scripted + none + cosine + consistency -> Task 1 (signatures match spec section 1; dry-script behaviour mirrors runLLMScripted as specced). OpenAI runEmbed + embedModel -> Task 2 Step 1 (spec section 2). Voyage module -> Task 2 Step 2 (spec section 3; config carries retry knobs instead of baseUrl — flagged in-task as a deviation to report, matching the OpenAI module's hardcoded-URL reality). SimilarTo + pass rule + constraint ripple + Embed.none migration -> Task 3 (spec section 4; the wider testSkill/improveSkill ripple is amended into the spec in Task 3 Step 5). Demo consistency + SimilarTo + Voyage gate -> Task 4 Steps 1-2 (spec Demo). Both manual sections -> Task 4 Step 3 (spec Manual). Tests map one-to-one onto the spec's Testing list; the "scores exactly as before under none" item is covered by the whole pre-existing battery running under the sweep, noted in Task 3 Step 3. manifest-evals handoff -> Task 5 Step 3. Non-goals absent from all tasks. ✅

**2. Placeholder scan:** none. The Voyage model-name verification and the aeson-operator adaptation are deliberate verify-against-reality instructions with concrete fallback actions, not gaps. ✅

**3. Type consistency:** `EmbedText :: Text -> Embed m [Double]` matches `embed :: Text -> Eff es [Double]` and both interpreters' `(\_ (EmbedText t) -> ...)`; `SimilarTo Double Text` ordering (threshold, reference) consistent across constructor, scoreWith arm (`SimilarTo _ ref`), passes arm (`SimilarTo t _`), tests, demo, and docs; scripted vector order (reference first) stated where tests depend on it; `cosine`/`consistency` names match between Crucible.Embed exports, Eval.hs imports, and test imports; both providers' `embedRequestJson`/`extractEmbedding` used qualified in tests to avoid ambiguity. Check counts: 253 + 5 + 4 + 5 = 267; the bead close message says 14 tests (5 + 4 + 5). ✅
