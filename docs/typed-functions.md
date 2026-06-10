---
title: Typed functions
nav_order: 4
---

# Typed functions

A typed skill wraps a prompt pattern (an instruction, an input codec, and an
output codec) into a single reusable value. Calling it produces a decoded,
strongly-typed result rather than raw text. Schema generation, prompt construction,
tolerant JSON extraction, and decode-failure retries are all handled for you.

## Skill and skill

`Skill i o` is the declared skill type: `i` is the Haskell input, `o` is the
decoded output. Construct one with:

```haskell
skill
  :: Text             -- name (for introspection / evals)
  -> JSONCodec i      -- input codec (renders the input value into the prompt)
  -> JSONCodec o      -- output codec (schema injection + tolerant decode)
  -> (i -> Text)      -- task instruction
  -> Skill i o
```

`retries` defaults to 2. Override it with `withRetries :: Int -> Skill i o -> Skill i o`.

## Calling a typed skill

```haskell
call :: (LLM :> es) => Skill i o -> i -> Eff es (Either DecodeError o)
```

`call` needs only `LLM :> es`. It runs unchanged under `runLLMScripted`,
`Anthropic.replay`, and `Anthropic.run`. The steps it performs:

1. Build a system message: `"Respond ONLY with JSON matching this schema:\n<schema>"`.
2. Build a user message: the instruction applied to the input, followed by the
   JSON-encoded input value.
3. Call `complete` to get the raw model reply.
4. Run `decodeLLM` on the reply.
5. On a decode failure: append the raw reply and the parse error to the conversation
   and loop back to step 3, up to `retries` times.
6. On exhaustion: return `Left err`.

The retry loop feeds the error back to the model so it can self-correct. With
`retries = 2` a transient formatting glitch rarely survives to `Left`.

## Codecs

Every input and output type needs a `JSONCodec`. The cleanest path is a `HasCodec`
instance backed by `genericCodec`, which works for any single-constructor record
with named fields:

```haskell
{-# LANGUAGE DeriveGeneric #-}

import GHC.Generics (Generic)
import Crucible.Codec.Generic (HasCodec (codec), genericCodec)

data Sentiment = Sentiment { sentLabel :: Text }
  deriving (Show, Generic)

instance HasCodec Sentiment where codec = genericCodec
```

For types you do not want to attach a class instance to, or for ad-hoc shapes, use
the facade combinators from `Crucible.Codec`:

| Combinator | Type |
|------------|------|
| `str`      | `JSONCodec Text` |
| `int`      | `JSONCodec Int` |
| `bool`     | `JSONCodec Bool` |
| `float`    | `JSONCodec Double` |
| `list'`    | `JSONCodec a -> JSONCodec [a]` |
| `nullable'`| `JSONCodec a -> JSONCodec (Maybe a)` |
| `enum`     | `Eq a => [(Text, a)] -> JSONCodec a` |
| `object`   | `ObjectCodec a a -> JSONCodec a` |
| `field`    | `Text -> (o -> f) -> JSONCodec f -> ObjectCodec o f` |
| `anyValue` | `JSONCodec Value` |

An `enum` example: a classifier whose output is one of three variants, without a
`data` type.

```haskell
import Crucible.Codec (JSONCodec, str, enum)
import Crucible.Skill (Skill, skill, call)

data Polarity = Positive | Negative | Neutral deriving (Eq, Show)

polarityCodec :: JSONCodec Polarity
polarityCodec = enum [("positive", Positive), ("negative", Negative), ("neutral", Neutral)]

classify :: Skill Text Polarity
classify = skill "classify-polarity" str polarityCodec
  (\s -> [text|Classify the sentiment of: ${s}|])
```

The codec provides both the JSON encode/decode path and the JSON Schema that is
injected into the system prompt.

## Writing instructions

The instruction is an ordinary `i -> Text`. crucible writes prompts with
[`neat-interpolation`](https://hackage.haskell.org/package/neat-interpolation)'s
`[text| … |]` quasiquoter: multi-line templates with `${var}` interpolation,
where the quasiquoter strips the block's leading indentation so the source mirrors
the output. Interpolated values must be `Text` identifiers in scope, so bind any
non-`Text` piece to a `let`/`where` first. Enable it with
`{-# LANGUAGE QuasiQuotes #-}` and `import NeatInterpolation (text)`:

```haskell
summarise :: Skill Text Text
summarise = skill "summarise" str str
  (\doc -> [text|
    Summarise the document below in one sentence.

    ${doc}|])
```

## Schema injection

`schemaText :: JSONCodec a -> Text` renders a codec's JSON Schema as compact JSON
text. `call` calls it on the output codec and prepends the result to the system
prompt:

```
Respond ONLY with JSON matching this schema:
{"type":"object","properties":{"sentLabel":{"type":"string"}},"required":["sentLabel"]}
```

The model sees the contract before it generates a single token. For `enum` codecs
the schema enumerates the permitted string values; for records it lists required
fields and their types. To inspect what will be sent (for prompt tuning, say),
call `schemaText fn.output` directly. To see the full seed conversation, use
`prompt :: Skill i o -> i -> [Message]`: it returns the exact messages `call`
sends for a given input (the System message carrying the schema contract, then
the User message with the instruction and the rendered input).

## Tolerant decode

Model output is rarely pristine JSON. `decodeLLM :: JSONCodec a -> Text -> Either DecodeError a` handles the common impurities:

1. `stripToJson` scans forward to the first `{` or `[`, extracts the balanced
   bracket group (respecting string literals), and returns that substring. Markdown
   fences, leading prose, and trailing explanation are all stripped automatically.
2. The extracted text is parsed as JSON via `aeson`.
3. The JSON value is decoded through the codec via autodocodec's `parseJSONVia`.

A failure at any step produces `Left (DecodeError { message, raw })`. Access the
human-readable description via `e.message` and the raw model reply via `e.raw`.
On failure `call` feeds `e.message` back to the model as a `User` message and
retries, as described above.

## Worked example: record output

From `app/Main.hs`, the canonical end-to-end demo:

```haskell
import Crucible.Skill (Skill, skill, call)
import Crucible.Decode (DecodeError (..))
import qualified Crucible.LLM.Anthropic as Anthropic

data Sentiment = Sentiment { sentLabel :: T.Text } deriving (Show, Generic)
instance HasCodec Sentiment where codec = genericCodec

let classify :: Skill T.Text Sentiment
    classify = skill "classify" str codec
      (\s -> [text|Classify the sentiment as positive, negative, or neutral for: ${s}|])

typed <- runEff (Anthropic.run cfg (call classify "I absolutely love this!"))
case typed of
  Right o  -> putStrLn (T.unpack (sentLabel o))   -- "positive"
  Left e   -> putStrLn ("decode error: " <> e.message)
```

## One codec, many uses

A type defined once, as `data Sentiment … ; instance HasCodec Sentiment where codec = genericCodec`, can be used as a skill output and as a tool argument codec
(via `schemaValue` → `schema`), all from the same single codec. See
[Tool calling](tool-calling.md) for the tool schema path and
[Getting started](getting-started.md) for the end-to-end wiring.
