# Crucible: user manual on GitHub Pages

**Goal.** A prose user manual for crucible, served on GitHub Pages with the same
setup as the sibling project manifest — Jekyll + the `just-the-docs` remote
theme, served from the repo's `docs/` folder. Includes creating crucible's first
GitHub repo (it is currently local-only) and enabling Pages.

**Why.** crucible has a substantial, battle-tested API (the typed LLM-agent
substrate) but no narrative documentation. manifest established a clean,
low-maintenance docs pattern (markdown pages, no build tooling, GitHub's native
Jekyll); crucible adopts the same so the two siblings match.

## Design decisions

1. **Mirror manifest's hosting exactly** — GitHub Pages from `docs/` on the
   default branch (`master`), Jekyll, `remote_theme: just-the-docs/just-the-docs`.
   No GitHub Actions, no mkdocs, no build step.
2. **Prose manual, not API reference** — page-per-concept narrative with real,
   compiling-style snippets drawn from `app/Main.hs` and the modules. Not
   generated Haddock.
3. **Docs-only change** — no crucible source changes except a small README
   "Documentation" link to the site. The published site excludes the
   `docs/superpowers/` specs/plans via `_config.yml`.
4. **Public repo** (user-authorised) — `garethstokes/crucible`, public, so free
   Pages serves it (matching manifest). The repo history is verified clean of
   secrets (`.env` is gitignored, untracked, and the API key never appears in
   history).

## Hosting setup

`docs/_config.yml` (mirrors manifest's):

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

Publish (final step, user-authorised): `gh repo create garethstokes/crucible
--public --source=. --remote=origin`, push `master`, then enable Pages
(branch `master`, path `/docs`) via `gh api`. Site URL:
`https://garethstokes.github.io/crucible`.

## Manual pages

Each page has `just-the-docs` front-matter (`title:`, `nav_order:`) and is
cross-linked. Snippets match the real crucible API.

1. **`docs/index.md`** (Home, nav 1) — what crucible is (LLM/Chat/Tools/Emit
   effects on `effectful`; typed functions; native tool-calling; SSE streaming;
   usage/cost; cassettes; autodocodec codecs; a live Anthropic interpreter), a
   hero snippet, and the page index.
2. **`docs/getting-started.md`** (nav 2) — `AnthropicConfig`, a first live
   `complete` under `runLLMAnthropic`, a typed function (`llmFn`/`call`), and a
   cassette replay for a hermetic test.
3. **`docs/effects.md`** (nav 3) — the substrate: `LLM` (`complete`), `Chat`
   (`converse`/`runToolAgent`), `Tools`, `Emit`; interpreters (scripted ·
   live · cassette · streaming) and the effectful pattern (one capability row,
   swap the interpreter at the edge).
4. **`docs/typed-functions.md`** (nav 4) — `LlmFn`, `llmFn`, `call`, `withRetries`;
   autodocodec codecs (`HasCodec`, `genericCodec`, the facade combinators);
   schema injection into the prompt; `Crucible.SAP` tolerant decode; the retry
   loop.
5. **`docs/tool-calling.md`** (nav 5) — `Tool`, `runToolAgent` /
   `runToolAgentN`, the request→run→result loop, unknown-tool / error feedback,
   the iteration cap (`ToolLoopExceeded`), and the tool `input_schema`.
6. **`docs/streaming.md`** (nav 6) — the `Emit` effect (`runEmitIO` /
   `ignoreEmit` / `runEmitList`), `runLLMAnthropicStream` /
   `runChatAnthropicStream`, live token deltas, and that streaming returns the
   assembled result plus `Usage`.
7. **`docs/usage-and-cassettes.md`** (nav 7) — the `Usage` monoid,
   `runLLMAnthropicUsage` / `runChatAnthropicUsage`, `estimateCost`/`Rates`; and
   record/replay cassettes (`recordLLMAnthropic`/`runLLMCassette`,
   `recordChatAnthropic`/`runChatCassette`) for hermetic CI.
8. **`docs/live-interpreter.md`** (nav 8) — `AnthropicConfig` (model, tokens,
   timeout, retries, stream-idle), the typed `AnthropicError`s + `isRetryable`,
   jittered-backoff retries, and the live wire path / cassette slider.

README gets a short "Documentation" section linking to
`https://garethstokes.github.io/crucible`.

## Testing / verification

- **Local link/structure check:** every cross-link resolves to an existing page;
  front-matter present on each; `_config.yml` excludes `superpowers/`.
- **Snippet fidelity:** each code snippet uses real exported symbols (spot-check
  names against the modules; the manual is prose, not compiled, so this is a
  review check, not a build).
- **Publish verification:** after `gh repo create` + push + Pages enable, confirm
  the repo exists and Pages is configured (`gh api .../pages` returns the source
  branch/path). The live URL may take a minute to build; confirm the Pages build
  was triggered.

## Non-goals

- No generated Haddock/API reference site.
- No CI/Actions docs pipeline (GitHub's native Jekyll only).
- No crucible code changes beyond the README link.
- Not documenting the in-progress SP5 (manifest persistence) — that ships later.

## Self-review

- **Placeholders:** none.
- **Consistency:** the `_config.yml`, `baseurl: /crucible`, and page set mirror
  manifest's pattern; pages map to crucible's actual shipped features.
- **Scope:** one focused docs sub-project — 8 markdown pages + config + a README
  link + the publish. One plan.
- **Ambiguity:** the publish is explicitly the final, user-authorised step
  (public repo); the manual is prose with real-API snippets (not compiled).
- **Dependency risk:** none (markdown + GitHub's hosted Jekyll); `gh` CLI auth
  required for the publish step.
