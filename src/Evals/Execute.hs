{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Run execution (sub-project C): assemble prompts, call the injected LLM
-- backend, persist one 'Output' per 'Example', and finish the run. Failure is
-- per-example: a model or decode error is recorded on that 'Output' and the
-- run still finishes @succeeded@. The run only goes @failed@ when the run or
-- its target version cannot be loaded.
module Evals.Execute
  ( ExecError (..)
  , renderExecError
  , LlmRunner
  , scriptedRunner
  , decodeInput
  , assembleMessages
  , usageJson
  , RunOutcome (..)
  , executeRun
  ) where

import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (SomeException, bracket_, try)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Types as AT
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (diffUTCTime, getCurrentTime)

import Crucible.LLM (Message (..), Role (..))
import Crucible.Usage (Usage (..))
import Manifest
import Manifest.Postgres (Pool)

import Evals.Ids
import Evals.Schema

-- | A per-example failure: the model call failed, or the example's @input@
-- jsonb is not in a shape we can turn into messages.
data ExecError = LlmError Text | InputDecodeError Text
  deriving (Eq, Show)

renderExecError :: ExecError -> Text
renderExecError (LlmError t)         = "llm: " <> t
renderExecError (InputDecodeError t) = "input: " <> t

-- | The injected model backend: a target version + assembled messages in, a
-- reply (with token usage) or an error out. Live = crucible's Anthropic
-- interpreter ("Evals.Execute.Anthropic"); tests inject their own.
type LlmRunner = TargetVersion -> [Message] -> IO (Either ExecError (Text, Usage))

-- | A no-network backend that ignores the target and pops replies from the
-- scripted list, cycling when exhausted. (An 'Data.IORef.IORef' pops across
-- calls — crucible's @runLLMScripted@ scopes its script to one @runEff@, i.e.
-- one call, so the cross-call cursor has to live out here.)
scriptedRunner :: [Text] -> IO LlmRunner
scriptedRunner replies
  | null replies = pure (\_ _ -> pure (Right ("", mempty)))
  | otherwise = do
      ref <- newIORef (cycle replies)
      pure $ \_ _ -> do
        t <- atomicModifyIORef' ref (\case (x : xs) -> (xs, x); [] -> ([], ""))
        pure (Right (t, mempty))

-- | An 'Example'\'s @input@ jsonb as conversation messages:
-- a JSON string is one user turn; @{"messages":[{role,content},…]}@ is a
-- multi-turn conversation (roles: system\/user\/assistant); anything else is
-- an 'InputDecodeError'.
decodeInput :: Value -> Either ExecError [Message]
decodeInput (String s) = Right [Message User s]
decodeInput v@(Object _) =
  either (Left . InputDecodeError . T.pack) Right (AT.parseEither parser v)
  where
    parser = AT.withObject "input" $ \o -> do
      items <- o AT..: "messages"
      mapM one items
    one = AT.withObject "message" $ \m -> do
      r <- m AT..: "role"
      c <- m AT..: "content"
      role <- case (r :: Text) of
        "system"    -> pure System
        "user"      -> pure User
        "assistant" -> pure Assistant
        _           -> fail ("unknown role: " <> T.unpack r)
      pure (Message role c)
decodeInput _ = Left (InputDecodeError "input must be a JSON string or {\"messages\": [...]}")

-- | The target's prompt as the system turn, then the example's conversation.
assembleMessages :: TargetVersion -> Example -> Either ExecError [Message]
assembleMessages tv ex = (Message System tv.prompt :) <$> decodeInput inputVal
  where Aeson inputVal = ex.input

-- | 'Usage' as the @Output.tokens@ jsonb. ('Usage' has no ToJSON upstream.)
usageJson :: Usage -> Value
usageJson u = object ["input_tokens" .= u.inputTokens, "output_tokens" .= u.outputTokens]

-- | What 'executeRun' did: example counts by fate.
data RunOutcome = RunOutcome
  { total     :: Int
  , succeeded :: Int
  , errored   :: Int
  , skipped   :: Int
  }
  deriving (Eq, Show)

-- | Execute a run: load the 'Run', its 'TargetVersion', its dataset version's
-- 'Example's and the already-output example ids (resume); mark @running@; for
-- each remaining example (bounded-concurrent) assemble + call the runner and
-- write one 'Output'; mark @succeeded@. A missing run\/target marks the run
-- @failed@ and returns an all-zero outcome.
executeRun :: Pool -> Int -> LlmRunner -> RunId -> IO RunOutcome
executeRun pool concurrency runner runId = do
  setup <- withSession pool $
    get @Run (Key runId) >>= \case
      Nothing -> pure Nothing
      Just run ->
        get @TargetVersion (Key run.targetVersion) >>= \case
          Nothing -> pure Nothing
          Just tv -> do
            examples <- selectWhere [ #datasetVersion ==. run.datasetVersion ]
            done     <- selectWhere [ #run ==. runId ]
            pure (Just (tv, examples :: [Example], map (.example) (done :: [Output])))
  case setup of
    Nothing -> do
      withSession pool $ update @Run (Key runId) [ #status =. "failed" ]
      pure RunOutcome { total = 0, succeeded = 0, errored = 0, skipped = 0 }
    Just (tv, examples, doneIds) -> do
      startedAt <- getCurrentTime
      withSession pool $
        update @Run (Key runId) [ #status =. "running", #startedAt =. Just startedAt ]
      sem <- newQSem (max 1 concurrency)
      let todo = [ ex | ex <- examples, ex.id `notElem` doneIds ]
      oks <- forConcurrently todo $ \ex ->
        bracket_ (waitQSem sem) (signalQSem sem) (runOne tv ex)
      finishedAt <- getCurrentTime
      withSession pool $
        update @Run (Key runId) [ #status =. "succeeded", #finishedAt =. Just finishedAt ]
      pure RunOutcome
        { total     = length examples
        , succeeded = length (filter id oks)
        , errored   = length (filter not oks)
        , skipped   = length examples - length todo
        }
  where
    -- One example: assemble, time the call, write the Output. Both error
    -- branches (assembly, model) record on the row; an unexpected exception
    -- from the runner is captured as an LlmError rather than killing the run.
    runOne :: TargetVersion -> Example -> IO Bool
    runOne tv ex = do
      t0 <- getCurrentTime
      result <- case assembleMessages tv ex of
        Left err   -> pure (Left err)
        Right msgs ->
          try (runner tv msgs) >>= \case
            Left (e :: SomeException) -> pure (Left (LlmError (T.pack (show e))))
            Right r                   -> pure r
      t1 <- getCurrentTime
      let ms = round (realToFrac (diffUTCTime t1 t0) * 1000 :: Double) :: Int
      case result of
        Right (txt, u) -> do
          _ <- withSession pool $ add (Output
            { id = OutputId 0, run = runId, example = ex.id
            , response = Nothing, text = Just txt, error = Nothing
            , latencyMs = Just ms, tokens = Just (Aeson (usageJson u)) } :: Output)
          pure True
        Left err -> do
          _ <- withSession pool $ add (Output
            { id = OutputId 0, run = runId, example = ex.id
            , response = Nothing, text = Nothing
            , error = Just (renderExecError err)
            , latencyMs = Just ms, tokens = Nothing } :: Output)
          pure False
