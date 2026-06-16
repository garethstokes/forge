# Crucible M6: Decision unification + pure reduce — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Make the 12-factor unification concrete: `Decision tool answer = CallTool | Done`, a `decisionCodec` that decodes a model reply into either a tool call or a final answer, and a pure `reduce` that turns a `Decision` into a `Step` (continue with a tool / halt with an answer). Zero new deps.

**Architecture:** New module `Crucible.Decision`. The decision codec is `oneOfC` over a tool codec and an answer codec (built with `Variant` matchers). `reduce` is total and pure — the heart of the (later) control loop, testable with no LLM. See spec §3, §8.

**Tech Stack:** GHC 9.6.5 via `nix develop`; zinc. `base`, `text`. Run zinc as `nix develop --command zinc <...>`.

**Already built & green (M0–M5):** JSON layer, `Schema`, `Codec` (`Codec(..)`, `object`/`field`, `Variant(..)`, `oneOfC`), `Codec.Generic`, `Crucible.SAP` (`decodeLLM`). `Crucible.Json.Decode as D` exports `decodeValue`. Member `zinc.toml` lib/test depends include `base text crucible`.

**Beads:** M6 = `crucible-cpz`. Claim at start; close at end.

---

## Task 1: `Decision` + `decisionCodec`

**Files:** Create `packages/crucible/src/Crucible/Decision.hs`; modify `packages/crucible/test/Spec.hs`.

First: `bd update crucible-cpz --claim`.

- [ ] **Step 1: Failing tests with a worked tool/answer example**

In `Spec.hs` add `import Crucible.Decision` (and `import Crucible.SAP (decodeLLM)` if not already imported), plus:
```haskell
data ToolCall = GetWeather Text | AddNums Int Int deriving (Eq, Show)
newtype Answer = Answer Text deriving (Eq, Show)

getWeatherCodec :: Codec Text                 -- {"city": string}
getWeatherCodec = C.object (C.field "city" id C.str)

addNumsCodec :: Codec (Int, Int)              -- {"a": int, "b": int}
addNumsCodec = C.object ((,) <$> C.field "a" fst C.int <*> C.field "b" snd C.int)

toolCallCodec :: Codec ToolCall
toolCallCodec = C.oneOfC
  [ C.Variant (codecSchema getWeatherCodec) (GetWeather <$> codecDecode getWeatherCodec)
      (\tc -> case tc of GetWeather city -> Just (codecEncode getWeatherCodec city); _ -> Nothing)
  , C.Variant (codecSchema addNumsCodec) (uncurry AddNums <$> codecDecode addNumsCodec)
      (\tc -> case tc of AddNums a b -> Just (codecEncode addNumsCodec (a, b)); _ -> Nothing) ]

answerCodec :: Codec Answer
answerCodec = C.object (Answer <$> C.field "answer" (\(Answer t) -> t) C.str)

decCodec :: Codec (Decision ToolCall Answer)
decCodec = decisionCodec toolCallCodec answerCodec
```
checks:
```haskell
  , check "decode tool-call -> CallTool"
      (Right (CallTool (GetWeather "Brisbane")))
      (decodeLLM decCodec "{\"city\":\"Brisbane\"}")
  , check "decode answer -> Done"
      (Right (Done (Answer "all set")))
      (decodeLLM decCodec "{\"answer\":\"all set\"}")
  , check "decision round-trips (tool)"
      (Right (CallTool (AddNums 2 3)))
      (decodeValue (codecDecode decCodec) (codecEncode decCodec (CallTool (AddNums 2 3))))
```
Run `nix develop --command zinc test` → FAIL (module not found).

- [ ] **Step 2: Implement `Decision` + `decisionCodec`**

`packages/crucible/src/Crucible/Decision.hs`:
```haskell
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Decision
  ( Decision(..)
  , decisionCodec
  , Step(..)
  , reduce
  ) where

import Crucible.Codec (Codec(..), Variant(..), oneOfC)

-- | Everything the model emits is one of these: a tool call or a final answer.
data Decision tool answer = CallTool tool | Done answer
  deriving (Eq, Show)

-- | Build a codec that decodes a reply into a Decision and encodes it back.
-- Tries the tool codec first, then the answer codec.
decisionCodec :: Codec tool -> Codec answer -> Codec (Decision tool answer)
decisionCodec toolC ansC = oneOfC
  [ Variant (codecSchema toolC)
            (CallTool <$> codecDecode toolC)
            (\d -> case d of CallTool t -> Just (codecEncode toolC t); _ -> Nothing)
  , Variant (codecSchema ansC)
            (Done <$> codecDecode ansC)
            (\d -> case d of Done a -> Just (codecEncode ansC a); _ -> Nothing) ]
```
> `CallTool <$> codecDecode toolC` uses the `Functor` instance on `Decoder` (covariant) — fine. There is intentionally no `Functor Codec`; the encode side is handled by the explicit `Variant` matchers.

- [ ] **Step 3: Run** → PASS. `nix develop --command zinc test`.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(m6): Decision unification + decisionCodec"
```

---

## Task 2: `Step` + pure `reduce`

**Files:** Modify `packages/crucible/src/Crucible/Decision.hs`, `Spec.hs`.

- [ ] **Step 1: Failing tests**

In `Spec.hs`:
```haskell
  , check "reduce CallTool -> Continue"
      (Continue (GetWeather "Brisbane"))
      (reduce (CallTool (GetWeather "Brisbane") :: Decision ToolCall Answer))
  , check "reduce Done -> Halt"
      (Halt (Answer "all set"))
      (reduce (Done (Answer "all set") :: Decision ToolCall Answer))
```
Run → FAIL (`Step`/`reduce` not defined).

- [ ] **Step 2: Implement `Step` + `reduce`** (in `Crucible/Decision.hs`)

```haskell
-- | The pure outcome of interpreting a Decision: run a tool, or stop.
data Step tool answer = Continue tool | Halt answer
  deriving (Eq, Show)

-- | Pure, total: the seam the control loop pivots on (no effects).
reduce :: Decision tool answer -> Step tool answer
reduce (CallTool t) = Continue t
reduce (Done a)     = Halt a
```
(`Step`/`reduce` are already in the module export list from Task 1.)

- [ ] **Step 3: Run** → PASS. `nix develop --command zinc test`.

- [ ] **Step 4: Commit + close M6**

```bash
git add -A && git commit -m "feat(m6): Step + pure reduce"
```
Run: `bd close crucible-cpz --reason="Decision tool/answer unification via decisionCodec (oneOfC); pure total reduce -> Step; decode/round-trip/reduce tests green"`

---

## Self-Review

**Spec coverage (§3, §8):** `Decision` + `decisionCodec` (Task 1); `Step` + `reduce` (Task 2). The control loop that consumes `Step` is M7 (needs the effect substrate). ✓
**Placeholder scan:** none.
**Type consistency:** `Decision(..)`/`decisionCodec`/`Step(..)`/`reduce` consistent across tasks and tests. `decisionCodec :: Codec tool -> Codec answer -> Codec (Decision tool answer)`; `reduce :: Decision tool answer -> Step tool answer`. Uses `Variant`/`oneOfC`/`Codec(..)` from `Crucible.Codec`; `decodeLLM` from `Crucible.SAP`.
**Caveats (not failures):** `decisionCodec` tries the tool codec before the answer codec, so if a model reply structurally matches BOTH shapes the tool wins — fine when tool/answer shapes are distinct (as in the test: `{"city"|"a","b"}` vs `{"answer"}`). The richer `reduce` that appends tool results to an evolving `AgentState` and feeds parse errors back belongs with the M7 control loop; M6's `reduce` is the pure core of that.
