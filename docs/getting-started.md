---
title: Getting started
nav_order: 2
---

# Getting started

This page covers the four steps to get productive with crucible: configure the
Anthropic provider, make a first live call, declare a typed function, and record a
cassette you can replay in CI without any network access. Every snippet is drawn
from `app/Main.hs`, the end-to-end smoke executable.

## 1. Config

`defaultAnthropicConfig :: Text -> AnthropicConfig` constructs a fully populated
config from an API key. The defaults: the model is
`claude-haiku-4-5-20251001`, the token cap is 1 024, the request timeout is 60 s,
and the retry budget is 3 attempts with a 500 ms backoff base. For a first call you
need only read the key from the environment and pass it in:

```haskell
import System.Environment (lookupEnv)
import qualified Data.Text as T
import Crucible.LLM.Anthropic (defaultAnthropicConfig)

main :: IO ()
main = do
  key <- maybe (error "ANTHROPIC_API_KEY not set") id <$> lookupEnv "ANTHROPIC_API_KEY"
  let cfg = defaultAnthropicConfig (T.pack key)
  -- cfg :: AnthropicConfig
```

To override a field, use record update:
`cfg { model = "claude-opus-4-5-20251001", maxTokens = 4096 }`. See
[The live interpreter](live-interpreter.md) for the full `AnthropicConfig` field
reference, timeout semantics, and retry behaviour.

## 2. A first live call

The `LLM` effect exports one smart constructor: `complete :: (LLM :> es) => [Message] -> Eff es Text`. A `Message` pairs a `Role` (`System`, `User`, `Assistant`,
or `Tool`) with the content text. Discharge the effect with `Anthropic.run` and
unwrap to `IO` with `runEff`:

```haskell
import Effectful (runEff)
import Crucible.LLM (Message (..), Role (..), complete)
import qualified Crucible.LLM.Anthropic as Anthropic

prompt :: [Message]
prompt =
  [ Message System "You are a terse assistant."
  , Message User   "Reply with exactly the word: pong"
  ]

main :: IO ()
main = do
  let cfg = defaultAnthropicConfig "sk-ant-..."
  reply <- runEff (Anthropic.run cfg (complete prompt))
  putStrLn reply   -- "pong"
```

`Anthropic.run` creates one TLS `Manager` upfront and issues one `POST
/v1/messages` per `complete`. The result is the first text content block in the
response. Network or HTTP failures are thrown as `AnthropicError`; transient ones
(429, 5xx, connection reset) are retried automatically up to `maxRetries` times.

See [Effects](effects.md) for a full picture of the effect rows; see [The live
interpreter](live-interpreter.md) for the wire details.

## 3. A typed skill

Instead of parsing free text yourself, declare a `Skill`: it binds an input codec,
an output codec, and a task instruction into a reusable value. `call` builds the
prompt, injects the output schema, and tolerantly decodes the reply. Start with a
`HasCodec` instance for your output type; one `genericCodec` line covers any
single-constructor record:

```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE QuasiQuotes #-}

import GHC.Generics (Generic)
import qualified Data.Text as T
import Effectful (runEff)
import NeatInterpolation (text)
import Crucible.Codec (str)
import Crucible.Codec.Generic (HasCodec (codec), genericCodec)
import Crucible.Skill (Skill, skill, call)
import qualified Crucible.LLM.Anthropic as Anthropic

data Sentiment = Sentiment { sentLabel :: T.Text }
  deriving (Show, Generic)

instance HasCodec Sentiment where codec = genericCodec

classify :: Skill T.Text Sentiment
classify = skill "classify" str codec
  (\s -> [text|Classify the sentiment as positive, negative, or neutral for: ${s}|])

main :: IO ()
main = do
  let cfg = defaultAnthropicConfig "sk-ant-..."
  result <- runEff (Anthropic.run cfg (call classify "I absolutely love this!"))
  case result of
    Right o  -> putStrLn (T.unpack (sentLabel o))   -- "positive"
    Left e   -> putStrLn ("decode error: " <> e.message)
```

`call` returns `Either DecodeError o`. On a decode failure it re-asks the model
(feeding back the parse error) up to `retries` times, which defaults to 2. The
type constraint is only `LLM :> es`, so `call classify` runs unchanged under the
scripted interpreter in tests. See [Typed functions](typed-functions.md) for codec
combinators, schema injection, tolerant decode, and `withRetries`.

## 4. A hermetic test

`Anthropic.record :: FilePath -> AnthropicConfig -> Eff (LLM:es) a -> Eff es a`
behaves exactly like `Anthropic.run` but tees each reply to a cassette file (one
JSON-encoded reply per line, appended in call order). `Anthropic.replay :: FilePath ->
Eff (LLM:es) a -> Eff es a` replays a recorded cassette: the same calls in the same
order, no network. The smoke executable in `app/Main.hs` demonstrates both:

```haskell
import qualified Crucible.LLM.Anthropic as Anthropic

let cassette = "/tmp/crucible-cassette.jsonl"
writeFile cassette ""  -- fresh file

-- live run: hits the network and writes the cassette
live <- runEff (Anthropic.record cassette cfg (complete prompt))

-- replay: reads the cassette, no network
replayed <- runEff (Anthropic.replay cassette (complete prompt))

-- they match
print (live == replayed)   -- True
```

Commit the cassette alongside your tests. Run `Anthropic.record` during
development and switch to `Anthropic.replay` in CI. A chat
cassette (`Anthropic.recordChat` / `Anthropic.replayChat`) covers the full
`Chat`/`runToolAgent` path the same way. See
[Usage & cassettes](usage-and-cassettes.md) for the full record/replay API and the
`Chat` variants.
