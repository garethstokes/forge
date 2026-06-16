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
