# neat-interpolation Prompt Templates — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert crucible's hand-concatenated prompt strings to `neat-interpolation`'s `[text| … ${var} … |]` quasiquoter at the library prompt-builders + the example instruction lambda.

**Architecture:** Add `neat-interpolation` (a TH quasiquoter library) as a lib dep; fix the flake so Template Haskell can link `libz.so`; then rewrite the System/User prompt strings in `Function`/`Agent`/`Eval` and the `classify` lambda in `Main` as `[text| |]` blocks, binding interpolated pieces as `Text` in `where`/`let`. Prompt text shifts cosmetically (accepted); affected exact-match tests are updated.

**Tech Stack:** Haskell GHC 9.10.1, `neat-interpolation` (Template Haskell), `text`. Build/test via `nix develop . --command zinc {build,test}`.

---

## Background for the implementer

- **Spec:** `docs/superpowers/specs/2026-06-10-neat-interpolation-prompts-design.md`.
- **Spike-confirmed facts:** `neat-interpolation` builds on 9.10.1; its `[text| |]` quasiquoter runs Template Haskell, which needs `libz.so` on `LD_LIBRARY_PATH` (the flake fix in Task 1) or the build fails with `libz.so: cannot open shared object file`.
- **`neat-interpolation` semantics:** `[text| … |]` produces `Text`; `${ident}` interpolates a `Text` value **in scope** (an identifier, not an arbitrary expression — bind expressions to a `Text` `let`/`where` first); it strips the common leading indentation of the block and trims the leading newline. So the *content* is preserved but whitespace shifts slightly.
- **Scope note:** `Crucible.Example` has no prompt string to convert (it drives `runAgent` + tools, not `llmFn`/`judge`); the example-idiom conversion is just `app/Main.hs`'s `classify` lambda.
- **Commit footer:** end every commit body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: dependency + flake fix

**Files:** Modify `flake.nix`, `zinc.toml` (+ `zinc.lock`).

- [ ] **Step 1: fix the flake for Template Haskell.** In `flake.nix`, the dev shell's `mkShell` is currently:

```nix
          default = pkgs.mkShell {
            packages = [
              ghc
              pkgs.git
              pkgs.haskellPackages.alex
              pkgs.haskellPackages.happy
            ];
          };
```

Replace it with (adds `pkgs.zlib` and a `shellHook` putting `libz.so` on the loader path — mirrors manifest's flake):

```nix
          default = pkgs.mkShell {
            packages = [
              ghc
              pkgs.git
              pkgs.haskellPackages.alex
              pkgs.haskellPackages.happy
              pkgs.zlib
            ];
            # Template Haskell (e.g. neat-interpolation's [text| |] quasiquoter)
            # loads the package closure at compile time and needs libz.so on the
            # loader path; zinc builds zlib but does not expose its shared lib.
            shellHook = ''
              export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.zlib ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            '';
          };
```

- [ ] **Step 2: add the dependency.** Run `nix develop . --command zinc add neat-interpolation` (resolves + freezes the lock; spike-verified). Then add `"neat-interpolation"` to the `[build.lib] depends` list in `zinc.toml`.

- [ ] **Step 3: build (still green; no conversions yet).** `nix develop . --command zinc build` → exit 0. `nix develop . --command zinc test` → `1 test suite(s) passed`. (This confirms the dep resolves and the flake/shell is intact before any quasiquoter is used.)

- [ ] **Step 4: commit.**

```bash
git add flake.nix zinc.toml zinc.lock
git commit -m "$(printf 'build: neat-interpolation dep + flake zlib/LD_LIBRARY_PATH for TH\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: convert `Crucible.Function.fnPrompt`

**Files:** Modify `src/Crucible/Function.hs`, `test/Spec.hs`.

Current `fnPrompt`:
```haskell
fnPrompt fn input =
  [ Message System ("Respond ONLY with JSON matching this schema:\n" <> schemaText (fnOutput fn))
  , Message User (fnInstruction fn input <> "\n\nInput:\n" <> jsonText (toJSONVia (fnInput fn) input))
  ]
```

- [ ] **Step 1: add the pragma + import.** In `src/Crucible/Function.hs` add `{-# LANGUAGE QuasiQuotes #-}` to the pragma block and `import NeatInterpolation (text)` with the other imports.

- [ ] **Step 2: rewrite `fnPrompt`.** Replace it with:

```haskell
fnPrompt :: LlmFn i o -> i -> [Message]
fnPrompt fn input =
  [ Message System [text|
      Respond ONLY with JSON matching this schema:
      ${schema}|]
  , Message User [text|
      ${instruction}

      Input:
      ${rendered}|]
  ]
  where
    schema      = schemaText (fnOutput fn)
    instruction = fnInstruction fn input
    rendered    = jsonText (toJSONVia (fnInput fn) input)
```

- [ ] **Step 3: build + find the failing assertion.** `nix develop . --command zinc build` → exit 0. `nix develop . --command zinc test` (then run `.zinc/build/spec` directly to see `FAIL` lines): the `fnPrompt` exact-message check will fail (whitespace shifted). Locate it in `test/Spec.hs` (grep `fnPrompt`).

- [ ] **Step 4: update the assertion to the new text.** Set the expected `[Message …]` value to what `fnPrompt` now produces (capture the `actual:` from the FAIL output, or reason it out from the `[text| |]` block: leading newline trimmed, indentation stripped — e.g. the System message becomes `"Respond ONLY with JSON matching this schema:\n" <> <schema>`, and the User message `<instruction> <> "\n\nInput:\n" <> <rendered>` — the same content, re-dedented). Re-run `nix develop . --command zinc test` → `1 test suite(s) passed`.

- [ ] **Step 5: commit.**

```bash
git add src/Crucible/Function.hs test/Spec.hs
git commit -m "$(printf 'refactor(prompts): fnPrompt via neat-interpolation [text| |]\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: convert `Crucible.Agent`

**Files:** Modify `src/Crucible/Agent.hs` (+ `test/Spec.hs` if a prompt-text assertion fails).

Current sites — `startAgent` system message and `runAgent`'s parse-failure reprompt:
```haskell
startAgent codec question = AgentState
  [ Message System ("Respond ONLY with JSON matching this schema:\n" <> schemaText codec)
  , Message User question ]
-- in runAgent's loop:
  Left err -> loop (append st1
    (Message User ("Your reply did not parse: " <> T.pack err
                   <> ". Respond with valid JSON only.")))
```

- [ ] **Step 1: add the pragma + import.** Add `{-# LANGUAGE QuasiQuotes #-}` and `import NeatInterpolation (text)` to `src/Crucible/Agent.hs`.

- [ ] **Step 2: rewrite `startAgent`'s system message:**

```haskell
startAgent codec question = AgentState
  [ Message System [text|
      Respond ONLY with JSON matching this schema:
      ${schema}|]
  , Message User question ]
  where schema = schemaText codec
```

- [ ] **Step 3: rewrite the reprompt** (bind the error text, then interpolate). Replace the `Left err ->` branch with:

```haskell
        Left err ->
          let e = T.pack err
          in loop (append st1
               (Message User [text|Your reply did not parse: ${e}. Respond with valid JSON only.|]))
```

- [ ] **Step 4: build + suite.** `nix develop . --command zinc build` → exit 0; `nix develop . --command zinc test`. If an Agent prompt-text assertion fails (most Agent tests assert *results* under the scripted interpreter, not prompt text — likely none fail), update it to the new string the same way as Task 2. Re-run → `1 test suite(s) passed`.

- [ ] **Step 5: commit.**

```bash
git add src/Crucible/Agent.hs test/Spec.hs
git commit -m "$(printf 'refactor(prompts): Agent startAgent + reprompt via neat-interpolation\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 4: convert `Crucible.Eval.judge` + `app/Main.hs` classify

**Files:** Modify `src/Crucible/Eval.hs`, `app/Main.hs` (+ `test/Spec.hs` if a prompt-text assertion fails).

Current `judge` prompt:
```haskell
raw <- complete
  [ Message System "You are a strict grader. Respond ONLY with JSON {\"vPass\": <bool>, \"vWhy\": <string>}."
  , Message User ("Rubric: " <> rubric <> "\nOutput to grade: " <> render actual) ]
```
Current Main `classify`:
```haskell
classify = llmFn "classify" str codec
  (\s -> "Classify the sentiment as positive, negative, or neutral for: " <> s)
```

- [ ] **Step 1: Eval — pragma + import + rewrite.** Add `{-# LANGUAGE QuasiQuotes #-}` and `import NeatInterpolation (text)` to `src/Crucible/Eval.hs`. Rewrite the `complete [...]` prompt (note: inside `[text| |]` quotes are literal — no `\"` escaping):

```haskell
  raw <- complete
    [ Message System [text|You are a strict grader. Respond ONLY with JSON {"vPass": <bool>, "vWhy": <string>}.|]
    , Message User [text|Rubric: ${rubric}
Output to grade: ${graded}|] ]
```

Add `graded = render actual` to `judge`'s `where` clause (create one if absent):

```haskell
  where graded = render actual
```

- [ ] **Step 2: Main — pragma + import + rewrite.** In `app/Main.hs` add `{-# LANGUAGE QuasiQuotes #-}` (it already has `OverloadedStrings`/`DeriveGeneric`) and `import NeatInterpolation (text)`. Rewrite the `classify` instruction:

```haskell
          classify = llmFn "classify" str codec
            (\s -> [text|Classify the sentiment as positive, negative, or neutral for: ${s}|])
```

- [ ] **Step 3: build + suite.** `nix develop . --command zinc build` → exit 0; `nix develop . --command zinc test`. Update any failing prompt-text assertion (likely none — Eval's `judge` tests assert the `Score`, not prompt text) to the new string. Re-run → `1 test suite(s) passed`.

- [ ] **Step 4: commit.**

```bash
git add src/Crucible/Eval.hs app/Main.hs test/Spec.hs
git commit -m "$(printf 'refactor(prompts): Eval grader + Main classify via neat-interpolation\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 5: live smoke run

**Files:** none (verification).

- [ ] **Step 1: build the exe + run live.** `nix develop . --command zinc build` (exit 0), then (key from `.env`, gitignored — never echo it):

```bash
nix develop . --command bash -c 'set -a; . ./.env; set +a; BIN=$(find .zinc/build -type f -name crucible-anthropic | head -1); "$BIN"'
```

Expected: the demo passes end-to-end with the reworded prompts — `typed fn:` prints a sentiment word (the `classify` prompt still elicits a one-word JSON answer), the tool agent answers, streaming + both cassettes work. The prompt rewording must NOT regress behaviour. Paste the output. If the live call fails for an environment reason (no network/key), report DONE_WITH_CONCERNS (build + suite green, live unverified).

- [ ] **Step 2: no commit needed** (Task 4 captured the code; this is verification only).

---

## Self-Review

**1. Spec coverage:**
- `neat-interpolation` lib dep → Task 1. ✅
- flake `zlib`/`LD_LIBRARY_PATH` (TH prerequisite) → Task 1. ✅
- Convert Function.fnPrompt → Task 2; Agent (startAgent + reprompt) → Task 3; Eval.judge + Main.classify → Task 4. ✅ (Example has no prompt — noted.)
- `${var}` over `where`/`let`-bound `Text` idiom → Tasks 2–4. ✅
- Update affected prompt-text tests (chiefly `fnPrompt`) → Tasks 2–4 test steps. ✅
- Build + suite + live smoke verification → Tasks 1–5. ✅
- Non-goals respected (no Main stdout `<>` chains; no new abstraction; no GHC bump). ✅

**2. Placeholder scan:** No TBD/TODO. The test-update steps say "capture the `actual:` and set expected" — this is the correct instruction for an accepted-cosmetic-shift change (the exact post-dedent string is determined at run time), not a placeholder; the System/User *content* is given verbatim.

**3. Type consistency:** every converted site adds the same `QuasiQuotes` + `import NeatInterpolation (text)` and binds interpolated pieces (`schema`/`instruction`/`rendered`/`e`/`graded`/`s`) as `Text` before `${…}`. `fnPrompt`/`startAgent`/`runAgent`/`judge`/`classify` keep their existing signatures (prompt *content* unchanged, only whitespace). The dep name `neat-interpolation` and import `NeatInterpolation (text)` are consistent across all tasks. ✅
