# Crucible: multiline prompt templates via neat-interpolation

**Goal.** Replace the hand-concatenated (`<>` + literal `"\n"`) prompt strings
with `neat-interpolation`'s `[text| … ${var} … |]` quasiquoter, so multi-line,
value-interpolated prompts read like the templates they are. Library
prompt-builders plus the example instruction lambdas are converted.

**Why.** Every prompt in crucible is built with `Text` literals and `<>`
(`"Respond ONLY with JSON matching this schema:\n" <> schemaText …`,
`fnInstruction fn input <> "\n\nInput:\n" <> …`, the parse-failure reprompt, the
grader prompt). Multi-line prompts with interpolated values read worst this way.
`neat-interpolation` gives multi-line `Text` with `${var}` interpolation and
strips common leading indentation, so the source template mirrors the output.

**Constraint that shaped the choice.** GHC 9.12's native `MultilineStrings` would
require a GHC bump that breaks the deliberate 9.10.1 alignment with manifest (and
gives no interpolation anyway). So: stay on 9.10.1, use a quasiquoter library.
`neat-interpolation` chosen over `string-interpolate` for its Text-template +
indentation-stripping fit. A spike confirmed it builds and works on 9.10.1.

## Design decisions

1. **`neat-interpolation` as a library dependency** (`zinc add neat-interpolation`),
   added to the lib `depends`. Plain Haskell + Template Haskell; spike-verified.
2. **`flake.nix` gains `zlib` on `LD_LIBRARY_PATH`** — the gating prerequisite.
   The `[text| |]` quasiquoter runs Template Haskell, which loads the package
   closure at compile time and needs `libz.so`; crucible's flake didn't expose
   it (`libz.so: cannot open shared object file`). Add `pkgs.zlib` to the dev
   shell `packages` and a `shellHook` exporting `LD_LIBRARY_PATH` — mirroring
   manifest's flake. (Any TH-based dependency needs this; it is a one-time fix.)
3. **Interpolate Text identifiers, not expressions.** `neat-interpolation`'s
   `${ident}` requires `ident` to be a `Text` in scope. So each converted site
   binds its interpolated pieces as `Text` in a `where`/`let` and references them
   as `${var}`.
4. **Cosmetic prompt-text shift is accepted** (user-confirmed). neat strips the
   common leading indentation and trims the leading newline, so the assembled
   prompt text changes whitespace slightly. The model is insensitive; exact-match
   tests are updated to the new strings.

## Sites converted

Each converted module gains `{-# LANGUAGE QuasiQuotes #-}` and
`import NeatInterpolation (text)`.

- **`src/Crucible/Function.hs`** — `fnPrompt`: the System schema message and the
  User instruction+input message become `[text| … |]` with `${schema}`,
  `${instruction}`, `${rendered}` bound in a `where`.
- **`src/Crucible/Agent.hs`** — `startAgent`'s system message (schema contract)
  and `runAgent`'s parse-failure reprompt (`"Your reply did not parse: ${err}.
  Respond with valid JSON only."`).
- **`src/Crucible/Eval.hs`** — `judge`'s grader prompt (the System grader
  instruction and the User rubric+output message).
- **`src/Crucible/Example.hs`** and **`app/Main.hs`** — the `llmFn` instruction
  lambdas (e.g. `classify`'s `\s -> "Classify the sentiment …: " <> s` →
  `\s -> [text|Classify the sentiment as positive, negative, or neutral for: ${s}|]`),
  so the examples model the idiom.

## Testing

- **Update prompt-text assertions** to the new (cosmetically shifted) strings —
  chiefly the `fnPrompt` exact-message check in `test/Spec.hs`, plus any
  Agent/Eval/Example test asserting exact prompt text. Most tests are behavioural
  (`runToolAgent`/`call`/`runAgent`/`judge` assert *results* under the scripted
  interpreter, not prompt text), so the change set is small.
- **Build + full suite green** under the updated flake (`nix develop . --command
  zinc {build,test}`).
- **Live smoke run** of `app/Main.hs` to confirm the converted prompts still
  elicit correct behaviour: `classify` returns a sentiment word, the tool agent
  answers, and the demo passes end-to-end (the prompt rewording must not regress
  the model's behaviour).

## Non-goals

- No conversion of `app/Main.hs`'s console-output `<>` chains (those are stdout,
  not prompts).
- No new prompt-templating abstraction — just the quasiquoter at existing sites.
- No GHC bump; no `string-interpolate`; no change to prompt *content* beyond
  whitespace.

## Self-review

- **Placeholders:** none.
- **Consistency:** the flake fix matches manifest's pattern; every converted site
  uses the same `QuasiQuotes` + `import NeatInterpolation (text)` + `${var}` over
  `where`-bound `Text` idiom; the dep is added once to the lib target.
- **Scope:** one small feature — a dep + a flake fix + ~5 prompt sites + a handful
  of test-string updates. One plan.
- **Ambiguity:** "library builders + example idioms" is pinned to the listed
  modules; Main's stdout chains are explicitly excluded; the cosmetic text shift
  is explicitly accepted.
- **Dependency risk:** low — `neat-interpolation` is small and spike-verified on
  9.10.1; the only environmental requirement (zlib/`LD_LIBRARY_PATH`) is in scope.
