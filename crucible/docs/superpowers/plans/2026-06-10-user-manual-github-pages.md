# Crucible User Manual on GitHub Pages — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A prose user manual for crucible served on GitHub Pages, mirroring sibling project manifest's Jekyll + just-the-docs setup.

**Architecture:** GitHub Pages from the `docs/` folder on `master`, GitHub's native Jekyll with `remote_theme: just-the-docs/just-the-docs` (no build tooling). Eight cross-linked markdown pages with just-the-docs front-matter; `_config.yml` excludes `docs/superpowers/`. Final step creates the public `garethstokes/crucible` repo, pushes, and enables Pages.

**Tech Stack:** Markdown + Jekyll (GitHub-hosted) + just-the-docs remote theme; `gh` CLI for publish.

---

## Background for the implementer

- **Spec:** `docs/superpowers/specs/2026-06-10-user-manual-github-pages-design.md`.
- **Template:** sibling `../manifest/docs/` (same machine) — `_config.yml` + per-concept `.md` pages with `--- title: … nav_order: N ---` front-matter, prose with real-API snippets, cross-linked. Match its voice and density.
- **Source of truth for snippets:** `app/Main.hs` is the canonical, compiling end-to-end demo (post aeson/autodocodec migration). Draw snippets from it and the module exports. The manual is **prose, not compiled**, so snippet fidelity is a review check (use real exported symbols), not a build.
- **Real API (verified, current):**
  - `Crucible.LLM`: `Role(..)`, `Message(..)`, `LLM(..)`, `complete :: (LLM :> es) => [Message] -> Eff es Text`, `runLLMScripted :: [Text] -> Eff (LLM:es) a -> Eff es a`.
  - `Crucible.LLM.Anthropic`: `AnthropicConfig(..)` (`acApiKey`/`acModel`/`acMaxTokens`/`acTimeoutSecs`/`acMaxRetries`/`acBaseDelayMicros`/`acStreamIdleSecs`), `defaultAnthropicConfig :: Text -> AnthropicConfig`, `AnthropicError(..)` (`AnthropicHttpError`/`AnthropicStatusError`/`AnthropicNoContent`/`AnthropicStreamTimeout`), `isRetryable`, `runLLMAnthropic`, `recordLLMAnthropic`, `runLLMCassette`, `runChatAnthropic`, `recordChatAnthropic`, `runChatCassette`, `runLLMAnthropicUsage`, `runChatAnthropicUsage` (each `… -> Eff es (a, Usage)`).
  - `Crucible.LLM.Anthropic.Stream`: `runLLMAnthropicStream`, `runChatAnthropicStream` (`(IOE:>es, Emit:>es) => AnthropicConfig -> Eff (… : es) a -> Eff es (a, Usage)`).
  - `Crucible.Emit`: `Emit`, `emit`, `runEmitIO :: (IOE:>es) => (Text -> IO ()) -> …`, `ignoreEmit`, `runEmitList`.
  - `Crucible.Chat`: `Chat`, `converse`, `runToolAgent`/`runToolAgentN`, `defaultMaxIterations`, `ChatError(ToolLoopExceeded)`, `Turn(..)`, `ToolUse(..)`, `Block(..)`, `ChatMsg(..)`, `runChatScripted`.
  - `Crucible.Tool`: `Tool(..)` (`toolName`/`toolSchema :: Value`/`toolRun :: Value -> Eff es Value`), `ToolName`, `ToolCall(..)`, `Tools`, `toolsHelp`.
  - `Crucible.Function`: `LlmFn`, `llmFn :: Text -> JSONCodec i -> JSONCodec o -> (i -> Text) -> LlmFn i o`, `call :: (LLM:>es) => LlmFn i o -> i -> Eff es (Either String o)`, `withRetries`, `fnPrompt`.
  - `Crucible.Codec`: `str`, `int`, `bool`, `float`, `enum`, `object`, `field`, `list'`, `nullable'`, `anyValue`, `schemaValue`, `schemaText`, `JSONCodec`. `Crucible.Codec.Generic`: `HasCodec(..)`, `genericCodec` (use `instance HasCodec T where codec = genericCodec`).
  - `Crucible.Usage`: `Usage(..)` (`usInputTokens`/`usOutputTokens`), `usTotalTokens`, `Rates(..)` (`rInputPerMTok`/`rOutputPerMTok`), `estimateCost`.
  - `Crucible.SAP`: `decodeLLM :: JSONCodec a -> Text -> Either String a`, `stripToJson`.
- The published site URL is `https://garethstokes.github.io/crucible`. Internal page links use relative `.md` (e.g. `[Effects](effects.md)`), matching manifest.
- **Commit footer:** end every commit body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: hosting config + README link

**Files:** Create `docs/_config.yml`; Modify `README.md`.

- [ ] **Step 1: create `docs/_config.yml`** verbatim:

```yaml
title: crucible
description: A typed LLM-agent substrate for Haskell on effectful.
remote_theme: just-the-docs/just-the-docs
url: https://garethstokes.github.io
baseurl: /crucible
search_enabled: true
heading_anchors: true
markdown_ext: "markdown,mkdown,mkdn,mkd,md,lhs"
aux_links:
  GitHub: https://github.com/garethstokes/crucible
exclude:
  - superpowers/
```

- [ ] **Step 2: add a Documentation section to `README.md`.** Append (or place near the top, matching the README's style):

```markdown
## Documentation

Full user manual: **https://garethstokes.github.io/crucible**
(sources in [`docs/`](docs/)).
```

- [ ] **Step 3: commit.**

```bash
git add docs/_config.yml README.md
git commit -m "$(printf 'docs(site): Jekyll _config.yml + README docs link\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: Home page (`docs/index.md`)

**Files:** Create `docs/index.md`.

- [ ] **Step 1: write `docs/index.md`** with this exact structure (front-matter verbatim; prose in the manifest voice):

```markdown
---
title: Home
nav_order: 1
---

# crucible

crucible is a typed LLM-agent substrate for Haskell, built on
[`effectful`](https://hackage.haskell.org/package/effectful). It models an agent
as a small set of capabilities — talking to a model, calling tools, streaming,
recording — each a dynamic effect you discharge with an interpreter you choose:
scripted for tests, live for production, a cassette for hermetic replay.

\`\`\`haskell
-- a typed function: a prompt in, a decoded value out
data Sentiment = Sentiment { sentLabel :: Text } deriving (Show, Generic)
instance HasCodec Sentiment where codec = genericCodec

classify :: LlmFn Text Sentiment
classify = llmFn "classify" str codec
  (\s -> "Classify the sentiment as positive, negative, or neutral for: " <> s)

main :: IO ()
main = do
  cfg <- defaultAnthropicConfig <$> getKey
  r <- runEff (runLLMAnthropic cfg (call classify "I absolutely love this!"))
  print r   -- Right (Sentiment {sentLabel = "positive"})
\`\`\`

## What's in the box

- **Effects** — `LLM` (`complete`), `Chat` (`converse`/`runToolAgent`), `Tools`,
  and `Emit` (streaming deltas), each with scripted, live, and cassette
  interpreters.
- **Typed functions** — declare an `LlmFn` with input/output codecs; the output
  schema is injected into the prompt and the reply tolerantly decoded.
- **Native tool-calling** — advertise tools and let the model drive a
  request→run→result loop (`runToolAgent`), capped and self-correcting.
- **Streaming** — server-sent events surfaced as an `Emit` effect; print tokens
  live while still getting the assembled result + token `Usage`.
- **Usage & cost** — a `Usage` monoid summed across calls, plus a pure
  `estimateCost`.
- **Cassettes** — record a live conversation and replay it deterministically,
  the slider between a live eval and a hermetic test.
- **Codecs** — one autodocodec `HasCodec` per type drives prompt schemas, tool
  `input_schema`, and JSON encode/decode (and makes the type persistable by
  sibling project [manifest](https://github.com/garethstokes/manifest)).

## Pages

- [Getting started](getting-started.md) — config, a first live call, a typed
  function, a cassette replay.
- [Effects](effects.md) — the capability effects and their interpreters.
- [Typed functions](typed-functions.md) — `llmFn`/`call`, codecs, schema
  injection, tolerant decode, retries.
- [Tool calling](tool-calling.md) — `runToolAgent`, the loop, the cap, tool
  schemas.
- [Streaming](streaming.md) — the `Emit` effect and the streaming interpreters.
- [Usage & cassettes](usage-and-cassettes.md) — token accounting and
  record/replay.
- [The live interpreter](live-interpreter.md) — `AnthropicConfig`, robustness,
  the wire path.
```

(Note: in the actual file, the ```haskell fences are real — the `\`\`\`` above is escaped only for this plan.)

- [ ] **Step 2: commit.**

```bash
git add docs/index.md
git commit -m "$(printf 'docs(site): home page\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: Getting started (`docs/getting-started.md`)

**Files:** Create `docs/getting-started.md`.

- [ ] **Step 1: write the page.** Front-matter `--- title: Getting started\nnav_order: 2 ---`. Cover, in prose with real snippets drawn from `app/Main.hs`:
  1. **Config** — `defaultAnthropicConfig :: Text -> AnthropicConfig` (key from `ANTHROPIC_API_KEY`), default model/tokens.
  2. **A first live call** — `runEff (runLLMAnthropic cfg (complete [Message System "...", Message User "..."]))`.
  3. **A typed function** — declare `Sentiment` + `instance HasCodec Sentiment where codec = genericCodec`; `classify = llmFn "classify" str codec (...)`; `runEff (runLLMAnthropic cfg (call classify "..."))` → `Either String Sentiment`.
  4. **A hermetic test** — `recordLLMAnthropic path cfg (complete prompt)` then `runLLMCassette path (complete prompt)` (no network); note the cassette is the slider to CI.
  Cross-link to [Effects](effects.md), [Typed functions](typed-functions.md), [Usage & cassettes](usage-and-cassettes.md).

- [ ] **Step 2: commit.**

```bash
git add docs/getting-started.md
git commit -m "$(printf 'docs(site): getting started\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 4: Effects (`docs/effects.md`)

**Files:** Create `docs/effects.md`.

- [ ] **Step 1: write the page.** Front-matter `title: Effects`, `nav_order: 3`. Cover:
  - The substrate idea: an agent's capabilities are dynamic `effectful` effects; a function's type lists exactly what it can do (`(LLM :> es) => …`), and you swap the interpreter at the edge without touching the logic.
  - `LLM` / `complete`; interpreters `runLLMScripted` (tests), `runLLMAnthropic` (live), `runLLMCassette` (replay).
  - `Chat` / `converse` + `runToolAgent`; `runChatScripted` vs `runChatAnthropic`/`runChatCassette`.
  - `Tools` (the tool-execution effect) and `Emit` (streaming deltas; see [Streaming](streaming.md)).
  - A small table: effect → smart ctor → interpreters. Show a `runLLMScripted ["pong"] (complete msgs)` pure example and the live counterpart side by side.
  Cross-link [Tool calling](tool-calling.md), [Streaming](streaming.md), [The live interpreter](live-interpreter.md).

- [ ] **Step 2: commit.**

```bash
git add docs/effects.md
git commit -m "$(printf 'docs(site): effects page\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 5: Typed functions (`docs/typed-functions.md`)

**Files:** Create `docs/typed-functions.md`.

- [ ] **Step 1: write the page.** Front-matter `title: Typed functions`, `nav_order: 4`. Cover:
  - `LlmFn i o` and `llmFn name inputCodec outputCodec instruction`; `call :: LlmFn i o -> i -> Eff es (Either String o)`.
  - Codecs: one `HasCodec` per type via `instance HasCodec T where codec = genericCodec`; the facade combinators (`str`, `int`, `bool`, `float`, `enum`, `object`/`field`, `list'`, `nullable'`); that the codec also yields the JSON Schema.
  - Schema injection: the output codec's schema is rendered into the system prompt (`schemaText`); the input is rendered via the input codec.
  - Tolerant decode: `Crucible.SAP.stripToJson` + `decodeLLM` pull JSON from prose; `withRetries` re-prompts on a decode failure.
  - A worked `Sentiment` (record) and an `enum` example. Note the interop kicker: the same `HasCodec` makes the type persistable by manifest.
  Cross-link [Tool calling](tool-calling.md), [Getting started](getting-started.md).

- [ ] **Step 2: commit.**

```bash
git add docs/typed-functions.md
git commit -m "$(printf 'docs(site): typed functions page\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 6: Tool calling (`docs/tool-calling.md`)

**Files:** Create `docs/tool-calling.md`.

- [ ] **Step 1: write the page.** Front-matter `title: Tool calling`, `nav_order: 5`. Cover:
  - `Tool { toolName, toolSchema :: Value, toolRun :: Value -> Eff es Value }`; the `toolSchema` is the JSON-Schema advertised as the model's `input_schema` (build it as an aeson Value, or from a type via `schemaValue (codec @Args)`).
  - `runToolAgent [Tool es] question :: Eff es (Either ChatError Text)` — the loop: advertise tools → model returns `tool_use`s → run them → feed results back → repeat until a text answer. Unknown-tool / tool-error feedback lets the model self-correct.
  - The cap: `runToolAgentN cap …`; `runToolAgent = runToolAgentN defaultMaxIterations` (10); exhaustion → `Left (ToolLoopExceeded cap)`.
  - A worked `get_weather` example (schema + `toolRun`), run under `runChatAnthropic`/`runChatAnthropicUsage`.
  Cross-link [Effects](effects.md), [Streaming](streaming.md).

- [ ] **Step 2: commit.**

```bash
git add docs/tool-calling.md
git commit -m "$(printf 'docs(site): tool calling page\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 7: Streaming (`docs/streaming.md`)

**Files:** Create `docs/streaming.md`.

- [ ] **Step 1: write the page.** Front-matter `title: Streaming`, `nav_order: 6`. Cover:
  - The `Emit` effect: `emit :: Text -> Eff es ()`; interpreters `runEmitIO (\t -> …)` (live print), `ignoreEmit` (discard), `runEmitList` (collect, tests). Streaming is a parallel effect — `LLM`/`Chat` are unchanged.
  - `runLLMAnthropicStream` / `runChatAnthropicStream :: (IOE:>es, Emit:>es) => AnthropicConfig -> Eff (… : es) a -> Eff es (a, Usage)`: token deltas are `emit`ted live while the full result + `Usage` come back at the end.
  - The worked snippet from `app/Main.hs`: `runEff (runEmitIO (\t -> TIO.putStr t >> hFlush stdout) (runLLMAnthropicStream cfg (complete prompt)))`.
  - Note: typed functions / SAP work under streaming unchanged (the assembled text is decoded at the end); incremental *typed* decoding is out of scope.
  Cross-link [Usage & cassettes](usage-and-cassettes.md), [The live interpreter](live-interpreter.md).

- [ ] **Step 2: commit.**

```bash
git add docs/streaming.md
git commit -m "$(printf 'docs(site): streaming page\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 8: Usage & cassettes (`docs/usage-and-cassettes.md`)

**Files:** Create `docs/usage-and-cassettes.md`.

- [ ] **Step 1: write the page.** Front-matter `title: Usage & cassettes`, `nav_order: 7`. Cover:
  - **Usage:** `Usage` is a `Monoid` (summing tokens); `runLLMAnthropicUsage` / `runChatAnthropicUsage` return `(a, Usage)` summed across every call (incl. each `runToolAgent` round). `estimateCost :: Rates -> Usage -> Double` with caller-supplied per-MTok `Rates` (no prices baked in). The Main usage snippet.
  - **Cassettes:** `recordLLMAnthropic path cfg` / `runLLMCassette path` (text path) and `recordChatAnthropic path cfg` / `runChatCassette path` (tool-calling) — record a live run to a file, replay deterministically with no network. The Main chat-cassette record→replay snippet; why this is the eval↔hermetic-test slider for CI.
  Cross-link [Streaming](streaming.md), [Getting started](getting-started.md).

- [ ] **Step 2: commit.**

```bash
git add docs/usage-and-cassettes.md
git commit -m "$(printf 'docs(site): usage & cassettes page\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 9: The live interpreter (`docs/live-interpreter.md`)

**Files:** Create `docs/live-interpreter.md`.

- [ ] **Step 1: write the page.** Front-matter `title: The live interpreter`, `nav_order: 8`. Cover:
  - `AnthropicConfig` fields: `acApiKey`, `acModel`, `acMaxTokens`, `acTimeoutSecs`, `acMaxRetries`, `acBaseDelayMicros`, `acStreamIdleSecs`; `defaultAnthropicConfig key` and its defaults.
  - Robustness: typed `AnthropicError` (`AnthropicHttpError` / `AnthropicStatusError Int Text` / `AnthropicNoContent` / `AnthropicStreamTimeout`), `isRetryable` (429/5xx/network retryable; others not), jittered exponential backoff up to `acMaxRetries`, the request timeout, and the mid-stream idle timeout (`acStreamIdleSecs`).
  - The wire path: `runLLMAnthropic`/`runChatAnthropic` POST `/v1/messages`; the cassette interpreters are the deterministic counterpart.
  Cross-link [Getting started](getting-started.md), [Streaming](streaming.md).

- [ ] **Step 2: review the whole manual for cross-link + symbol fidelity.** Grep that every `[...](X.md)` target exists (all of: index, getting-started, effects, typed-functions, tool-calling, streaming, usage-and-cassettes, live-interpreter); each page has front-matter; `_config.yml` excludes `superpowers/`. Spot-check that snippet symbols are real exports (cross-reference the Background list). Fix any dangling link/name.

- [ ] **Step 3: commit.**

```bash
git add docs/live-interpreter.md
git commit -m "$(printf 'docs(site): live interpreter page + cross-link pass\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 10: publish — create repo, push, enable Pages

**Files:** none (GitHub setup). User-authorised public publish.

- [ ] **Step 1: confirm `gh` auth.** `gh auth status` (must be logged in as the account owning `garethstokes`). If not authenticated, STOP and report — the user runs `gh auth login` (or `! gh auth login`).

- [ ] **Step 2: create the public repo + push.** From the repo root (on `master`, tree clean):

```bash
gh repo create garethstokes/crucible --public --source=. --remote=origin --description "A typed LLM-agent substrate for Haskell on effectful." --push
```

(This creates the GitHub repo, adds `origin`, and pushes `master`. Verify with `git remote -v` and `gh repo view garethstokes/crucible --json url`.)

- [ ] **Step 3: enable GitHub Pages from the `docs/` folder on `master`.**

```bash
gh api -X POST repos/garethstokes/crucible/pages \
  -f "source[branch]=master" -f "source[path]=/docs"
```

(If Pages is already enabled, use `-X PUT repos/garethstokes/crucible/pages` to update the source.)

- [ ] **Step 4: verify.** `gh api repos/garethstokes/crucible/pages` returns the configured `source` (branch `master`, path `/docs`) and an `html_url` of `https://garethstokes.github.io/crucible/`. Confirm a Pages build was triggered (`gh api repos/garethstokes/crucible/pages/builds/latest`). The live site may take 1–2 minutes to publish. Report the URL.

---

## Self-Review

**1. Spec coverage:**
- Jekyll `_config.yml` mirroring manifest (theme, baseurl `/crucible`, exclude `superpowers/`) → Task 1. ✅
- README documentation link → Task 1. ✅
- 8 pages (index, getting-started, effects, typed-functions, tool-calling, streaming, usage-and-cassettes, live-interpreter) → Tasks 2–9. ✅
- Prose with real-API snippets anchored to `app/Main.hs` + exports → Background list + each page task. ✅
- Cross-link/symbol verification → Task 9 Step 2. ✅
- Create public repo + push + enable Pages + verify → Task 10. ✅
- Non-goals respected (no Haddock site, no Actions, docs-only, superpowers excluded). ✅

**2. Placeholder scan:** No TBD/TODO. `index.md` and `_config.yml` are given verbatim; the other pages are specified as front-matter + section list + required real-API snippets (the correct granularity for prose — the spec of each page is complete; the prose is authored at execution). The escaped ```` ``` ```` in the index template is noted to be real fences in the file.

**3. Consistency:** page filenames, `nav_order` (1–8), and cross-link targets match across all tasks and `index.md`'s Pages list; the API symbols in the Background list match the names used in every page task; `baseurl`/repo/URL (`garethstokes/crucible`, `/crucible`, `https://garethstokes.github.io/crucible`) are consistent in `_config.yml`, README, and Task 10. ✅
