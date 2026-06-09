# Crucible: backlog cleanups bundle

**Goal.** Three independent, low-risk cleanups, grouped into one short plan:
configurable tool-loop cap (`crucible-19f`), DRY the Anthropic HTTP plumbing
shared by the blocking and streaming paths (`crucible-gkw`), and fix the Main
typed-function demo so it round-trips reliably (`crucible-1cb`).

These are unrelated except in being small. They share no code and can land in
any order. One spec/plan for convenience.

## 1. `crucible-19f` — configurable tool-loop cap

**Problem.** `runToolAgent` hardcodes `defaultMaxIterations` (10), and
`ToolLoopExceeded` always reports `10` even though the loop is the only entry
point — so a future configurable cap would mis-report.

**Design.** Add a cap-taking variant; keep `runToolAgent` as the default-cap
wrapper (non-breaking — `runToolAgent`'s signature is unchanged):

```haskell
-- | Like 'runToolAgent' but with an explicit iteration cap.
runToolAgentN :: (Chat :> es) => Int -> [Tool es] -> Text -> Eff es (Either ChatError Text)

runToolAgent :: (Chat :> es) => [Tool es] -> Text -> Eff es (Either ChatError Text)
runToolAgent = runToolAgentN defaultMaxIterations
```

`runToolAgentN cap` runs the loop starting from `cap`; on exhaustion it returns
`Left (ToolLoopExceeded cap)` — the **actual** budget, not the hardcoded
default. (The loop closes over the outer `cap` for the error; the countdown `n`
is only used for termination.) Export `runToolAgentN` from `Crucible.Chat`.

**Testing** (`test/Spec.hs`, pure, via `runChatScripted`):
- `runToolAgentN 2` over a script that always returns a tool-use turn →
  `Left (ToolLoopExceeded 2)` (proves the cap is honoured *and* reported).
- The existing default-cap test (`runToolAgent` over 20 tool turns →
  `Left (ToolLoopExceeded 10)`) stays green (proves the wrapper still caps at 10).

## 2. `crucible-gkw` — DRY the Anthropic HTTP plumbing

**Problem.** `openStream` (`Crucible.LLM.Anthropic.Stream`) duplicates ~20 lines
from `postMessages` (`Crucible.LLM.Anthropic`): the request builder
(`parseRequest` + POST + `x-api-key`/`anthropic-version`/`content-type` headers +
`RequestBodyLBS` body), the `recovering` retry policy with the `AnthropicError`
handler, and the `maxBackoffMicros = 30000000` constant.

**Design.** Extract two helpers into `Crucible.LLM.Anthropic` (exported) and have
both callers use them:

```haskell
-- | Build the POST /v1/messages request for a JSON body, with the shared
-- headers. (Streaming adds an Accept header on top of the returned request.)
messagesRequest :: AnthropicConfig -> Value -> IO Request

-- | Wrap an IO action in the shared retry policy: jittered exponential backoff
-- capped at 'maxBackoffMicros', up to 'acMaxRetries', retrying 'AnthropicError's
-- for which 'isRetryable' holds.
withAnthropicRetry :: AnthropicConfig -> IO a -> IO a
```

- `postMessages` becomes `withAnthropicRetry cfg $ handle httpToAnthropic $ do {
  req <- messagesRequest cfg body; resp <- httpLbs req mgr; … status check … }`.
- `openStream` becomes `withAnthropicRetry cfg $ handle httpToAnthropic $ do {
  req0 <- messagesRequest cfg body; let req = addAcceptHeader req0; resp <-
  responseOpen req mgr; … status check … }`.
- `maxBackoffMicros` now lives once in `Anthropic.hs`; the `Stream.hs` duplicate
  is deleted (`Stream.hs` no longer needs `recovering`/`capDelay`/
  `fullJitterBackoff`/`limitRetries`/`Handler` imports — drop the now-unused
  ones).
- What stays per-caller (legitimately different): the `HttpException →
  AnthropicHttpError` handler wraps each caller's own call (`httpLbs` vs
  `responseOpen`), and the non-2xx status handling differs (blocking reads the
  whole body; streaming drains + closes the open response). The `Accept:
  text/event-stream` header is streaming-only.

**Behaviour-preserving.** No observable change to either path. Verified by the
existing test suite staying green and the live demo (Task 8 streaming + the
blocking M8 path) continuing to work. No new tests required for this refactor;
its contract is "the suite stays green + build succeeds".

## 3. `crucible-1cb` — object-output Main demo

**Problem.** The Main typed-fn demo declares `classify` with a **scalar `str`**
output codec. SAP's `stripToJson` locates the first `{`/`[` group, so a scalar
reply has no anchor and the model tends to wrap or prose its answer — the demo
prints `typed fn decode error: …` on live runs.

**Design.** Replace the scalar function with a small record output that
round-trips reliably, in `app/Main.hs`:

```haskell
data Sentiment = Sentiment { sentLabel :: Text } deriving (Show, Generic)
instance HasCodec Sentiment   -- default genericCodec

-- in main:
let classify :: LlmFn Text Sentiment
    classify = llmFn "classify" str codec
      (\s -> "Classify the sentiment as positive, negative, or neutral for: " <> s)
typed <- runEff (runLLMAnthropic cfg (call classify "I absolutely love this!"))
case typed of
  Right o  -> TIO.putStrLn ("typed fn: " <> sentLabel o)
  Left err -> TIO.putStrLn ("typed fn decode error: " <> T.pack (D.message err))
```

The output schema injected into the prompt is now an object
(`{"sentLabel": <string>}`), the model returns `{"sentLabel":"positive"}`,
`stripToJson` extracts it, and the codec decodes cleanly. New imports in
`Main.hs`: `GHC.Generics (Generic)`, `Crucible.Codec.Generic (HasCodec (codec))`,
`Crucible.Function (LlmFn)` (alongside the existing `llmFn`/`call`); add
`{-# LANGUAGE DeriveGeneric #-}` (and `DeriveAnyClass` if the empty instance
needs it — prefer a standalone `instance HasCodec Sentiment` which needs only
the default method). Demo-only change; verified by build + a live run printing
`typed fn: positive`.

**Note (not a bug to fix here).** Scalar LLM outputs are inherently fragile
through an object-oriented extractor; using a structured output is the correct
pattern and what the demo should model. No SAP change.

## Self-review

- **Placeholders:** none.
- **Consistency:** `runToolAgentN`/`runToolAgent` share the loop; `ToolLoopExceeded`
  reports the cap actually used. `messagesRequest`/`withAnthropicRetry` are the
  single source for request building + retry across both HTTP callers.
  `Sentiment`/`HasCodec`/`codec` follow the existing `Forecast`/`Station` pattern
  in `test/Spec.hs`.
- **Scope:** three small, independent changes — one plan, ~3 tasks. No new deps.
- **Ambiguity:** 19f keeps `runToolAgent` non-breaking (new variant); gkw is
  behaviour-preserving (verified by green suite, no new tests); 1cb is demo-only
  and uses an object output.
- **Dependency risk:** none.
