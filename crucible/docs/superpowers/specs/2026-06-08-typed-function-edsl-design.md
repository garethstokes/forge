# Crucible: typed-function eDSL (`Crucible.Function`)

**Goal.** Add the BAML-inspired ergonomic surface the v1 epic describes: a typed
LLM *function* — declared once with an input type, an output type, and a task
instruction — that you `call` to get a typed, structured result. It turns the
existing primitives (`Codec`, `renderSchema`, `decodeLLM`, the `LLM` effect)
into a single high-level combinator, with structured-output enforcement
(schema injection + tolerant decode + retry-with-feedback).

**Non-goals (YAGNI).** No string-template engine (the template is a Haskell
function). No new JSON/HTTP machinery (built entirely on existing primitives).
No provider coupling (`call` is interpreter-agnostic). No streaming, no native
tool-calling — those are separate directions.

## Design decisions

1. **Prompt model:** author writes a task *instruction*; Crucible auto-injects
   the rendered **output schema** and the rendered **input value**, and handles
   decode + retry. (Author controls phrasing; Crucible owns the I/O contract.)
2. **Template form:** the instruction is a Haskell function `i -> Text` —
   type-safe, no template engine.
3. **Failure handling:** on a decode failure, re-ask the model with the parse
   error fed back (configurable, default 2 retries); on exhaustion return
   `Left`. Result type `Eff es (Either Error o)` — total and explicit, matching
   `decodeLLM`'s `Either` style.
4. **Surface:** a declarative value `LlmFn i o` plus `call` — introspectable
   (name/codecs), reusable, and directly feedable to the M10 eval harness.

## API

New module `Crucible.Function` (imported directly, like the other `Crucible.*` modules — the umbrella `Crucible` module exports nothing):

```haskell
data LlmFn i o = LlmFn
  { fnName        :: Text       -- for introspection / evals
  , fnInstruction :: i -> Text  -- the task (may reference input fields)
  , fnInput       :: Codec i    -- Crucible auto-renders the input value
  , fnOutput      :: Codec o    -- schema injection + tolerant decode
  , fnRetries     :: Int        -- decode-failure retries
  }

-- | Smart constructor; fnRetries defaults to 2.
llmFn :: Text -> Codec i -> Codec o -> (i -> Text) -> LlmFn i o

withRetries :: Int -> LlmFn i o -> LlmFn i o

-- | Run a typed function. Interpreter-agnostic: needs only LLM :> es, so it
-- works under the scripted, cassette, and live Anthropic interpreters.
call :: (LLM :> es) => LlmFn i o -> i -> Eff es (Either Error o)
```

`Error` is `Crucible.Json.Decode.Error` (the type `decodeLLM` already returns).

## Behaviour (`call`)

Built only on `complete`, `renderSchema`, `codecSchema`, `encode`,
`codecEncode`, and `decodeLLM` — mirroring the conventions in
`Crucible.Agent.startAgent`/`runAgent`.

1. Seed the transcript:
   - **System:** `"Respond ONLY with JSON matching this schema:\n" <> renderSchema (codecSchema (fnOutput fn))`
   - **User:** `fnInstruction fn input <> "\n\nInput:\n" <> encode (codecEncode (fnInput fn) input)`
2. `raw <- complete transcript`.
3. `decodeLLM (fnOutput fn) raw`:
   - `Right o` → return `Right o`.
   - `Left err` → if retries remain, append a **User** message
     `"Your reply did not parse: " <> message err <> ". Respond with valid JSON only."`,
     decrement the budget, and loop from step 2; else return `Left err`.

The retry/feedback loop is the same shape as `runAgent`'s parse-error branch, so
the two stay consistent (a future refactor could share a helper; not required
here).

## Properties

- **Interpreter-agnostic.** `call :: (LLM :> es) => …` — no `IOE`. The same
  `LlmFn` is exercised by `runLLMScripted` (tests), `runLLMCassette` (replay),
  and `runLLMAnthropic` (live).
- **Eval-ready.** An `LlmFn` is a named value carrying its input/output codecs,
  so `Crucible.Eval.runEval` can drive `\i -> call fn i` over a dataset.
- **No new primitives.** Purely a composition of existing modules.

## Testing

Pure, deterministic via `runLLMScripted` (no network):

- **happy path:** scripted reply is valid JSON for `fnOutput` → `Right o`.
- **retry path:** first reply unparseable, second valid → `Right o`
  (asserts the feedback loop re-asks).
- **exhaustion:** all replies unparseable → `Left err`.
- **schema injection:** the seeded System message contains
  `renderSchema (codecSchema (fnOutput fn))` (so the model is told the contract).

Plus extend the M8 smoke exe (`app/Main.hs`) with one live typed-function call
to demonstrate end-to-end (`runLLMAnthropic`).

## Self-review

- **Placeholders:** none.
- **Consistency:** `call`'s `Either Error o` matches `decodeLLM`'s return; the
  prompt assembly matches `startAgent`/`runAgent` conventions.
- **Scope:** single module + tests + a smoke-exe line — one implementation plan.
- **Ambiguity:** the instruction is the *task* (Crucible separately appends the
  rendered input + output schema), so an author who also weaves the input into
  the instruction merely repeats it harmlessly — acceptable, documented here.
