# Penalty Criteria Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Negative-weight (penalty) criteria in checklists: autorubric's clamped formula (positive weights set the denominator, penalties subtract, clamp to [0,1]), a `penalty` constructor, and penalty-aware rationale lines.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-13-penalty-criteria-design.md` (tracker `crucible-nwa`). The change is local to `Crucible.Eval`: `checklistScore`'s `val` and line renderer, plus a `penalty` constructor. The strict pass rule needs no change (`Checklist` already uses `passes _ v = v >= 1.0`).

**Tech Stack:** Haskell GHC 9.12.2, effectful. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). Exit 137 = GHC iserv flake, retry once; second 137 = BLOCKED. Judge success by exit status or the pass line, never a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/penalty-criteria` from master; work in place, no worktrees.
- House style: DuplicateRecordFields, NoFieldSelectors, OverloadedRecordDot, prefix-free fields. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Read first: `src/Crucible/Eval.hs` lines ~64-72 (`Criterion`, `criterion`) and ~154-173 (`checklistScore`). The per-criterion judging (`judge1`) is unchanged: every criterion is judged with the same "the output must satisfy: `<label>`" call, so for a penalty (label = the BAD property) a `true` verdict means the penalty fired.
- The suite passes with 280 checks. Existing checklist tests use only positive weights and must stay green (regression guard): the new formula reproduces 2/3, 1.0, 1.0, 0.5.
- API keys live in `.env` (gitignored). NEVER print, echo, or cat `.env` or any key value.

---

### Task 1: formula + `penalty` constructor + tests

**Files:**
- Modify: `src/Crucible/Eval.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: `penalty` constructor.** In `src/Crucible/Eval.hs`, after `criterion` (line ~72), add:

```haskell
-- | A penalty criterion: a failure mode to subtract for. Give a positive
-- magnitude; the stored weight is negative. The label names the BAD
-- property ("recommends a specific product"), so the judge fires the
-- penalty when that property is present, lowering the score.
penalty :: Double -> Text -> Criterion
penalty w l = Criterion l (negate (abs w))
```

Add `penalty` to the export list (line 17, after `criterion`): `..., Criterion(..), criterion, penalty`.

- [ ] **Step 2: update the `Criterion` Haddock** (lines ~64-67) to cover penalties:

```haskell
-- | One checklist item: a concrete, observable requirement and its weight.
-- Write observable criteria ("cites a source URL"), not aspirational ones
-- ("is trustworthy"). A positive weight rewards; a negative weight (build
-- it with 'penalty') subtracts for a failure mode. A checklist case passes
-- (counts in 'Report.passRate') only when every positive criterion holds
-- and no penalty fires.
data Criterion = Criterion { label :: Text, weight :: Double }
```

- [ ] **Step 3: replace `checklistScore`** (lines ~154-173) with the clamped, positive-weight-denominator formula and penalty-aware lines:

```haskell
-- | Judge each criterion with its own binary call. The score is the signed
-- sum of passed-criterion weights over the sum of POSITIVE weights, clamped
-- to [0,1]: positive criteria reward, negative (penalty) criteria subtract,
-- and a perfect response scores 1.0 (penalties are not in the denominator).
-- value reaches 1.0 only when every positive criterion passes and no penalty
-- fires. A judge error on a criterion fails that criterion with a tagged line.
checklistScore :: (LLM :> es) => Int -> (a -> Text) -> [Criterion] -> a -> Eff es Score
checklistScore _ _ [] _ = pure (score 1.0 "empty checklist")
checklistScore n render cs actual = do
  rs <- mapM judge1 cs
  let posTotal = sum [c.weight | c <- cs, c.weight > 0]
      got      = sum [c.weight | (c, passed, _) <- rs, passed]
      clamp    = max 0.0 . min 1.0
      val | posTotal > 0 = clamp (got / posTotal)
          | got < 0      = 0.0
          | otherwise    = 1.0
      ln (c, p, w)
        | c.weight < 0 = (if p then "[penalty] " else "[clear] ") <> c.label <> ": " <> w
        | otherwise    = (if p then "[pass] "    else "[fail] ")  <> c.label <> ": " <> w
  pure (score val (T.intercalate "\n" (map ln rs)))
  where
    judge1 c = do
      out <- vote True defaultJudgeOpts { votes = n } ("the output must satisfy: " <> c.label) (render actual)
      pure $ case out of
        AllErrored m      -> (c, False, "judge error: " <> m)
        Decided p w _ _ _ -> (c, p, w)
```

(The old `total`/`allPass` bindings are gone; `clamp` is a local where the let sees it regardless of order. `c.weight` is the numeric weight; the tuple's `w` is the per-criterion rationale text.)

- [ ] **Step 4: tests in `test/Spec.hs`.** `penalty` arrives via the existing `Crucible.Eval` import (add it to that import list). Add after the existing checklist checks (the "checklist: judge error on a criterion fails that criterion" check, ~line 1048):

```haskell
  -- crucible-nwa: penalty criteria (negative weights)
  , check "checklist: a fired penalty subtracts; positives set the denominator"
      True
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"y\",\"pass\":true}"
                 , "{\"why\":\"fired\",\"pass\":true}" ]
                 (Embed.none (scoreM id
                    (Checklist [Criterion "helpful" 2, penalty 1 "recommends a product"]) ("out" :: Text))))
       in abs (s.value - 0.5) < 1e-9)
  , check "checklist: a heavy penalty clamps the score at 0"
      0.0
      ((runPureEff (runLLMScripted
         [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"fired\",\"pass\":true}" ]
         (Embed.none (scoreM id
            (Checklist [Criterion "helpful" 2, penalty 5 "recommends a product"]) ("out" :: Text))))).value)
  , check "checklist: a penalty present but not fired keeps the case perfect"
      (1.0, 1.0)
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}"
                   , "{\"why\":\"absent\",\"pass\":false}" ]
                   (Embed.none (runEval id pure
                      [Case ("in" :: Text) "c" (Checklist [Criterion "helpful" 2, penalty 3 "recommends a product"])])))
       in (rep.passRate, rep.meanScore))
  , check "checklist: a fired penalty drops the case out of passRate"
      (0.0, True)
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"fired\",\"pass\":true}" ]
                   (Embed.none (runEval id pure
                      [Case ("in" :: Text) "c" (Checklist [Criterion "helpful" 2, penalty 1 "recommends a product"])])))
       in (rep.passRate, abs (rep.meanScore - 0.5) < 1e-9))
  , check "checklist: a penalty-only checklist scores 1.0 clear, 0.0 fired"
      (1.0, 0.0)
      ( (runPureEff (runLLMScripted ["{\"why\":\"absent\",\"pass\":false}"]
          (Embed.none (scoreM id (Checklist [penalty 2 "recommends a product"]) ("out" :: Text))))).value
      , (runPureEff (runLLMScripted ["{\"why\":\"fired\",\"pass\":true}"]
          (Embed.none (scoreM id (Checklist [penalty 2 "recommends a product"]) ("out" :: Text))))).value )
  , check "checklist: rationale uses [penalty]/[clear] for negatives, [pass]/[fail] for positives"
      (True, True, True)
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"y\",\"pass\":true}"
                 , "{\"why\":\"fired\",\"pass\":true}"
                 , "{\"why\":\"absent\",\"pass\":false}" ]
                 (Embed.none (scoreM id (Checklist
                    [ Criterion "helpful" 1
                    , penalty 1 "recommends a product"
                    , penalty 1 "uses slang" ]) ("out" :: Text))))
       in ( T.isInfixOf "[pass] helpful" s.rationale
          , T.isInfixOf "[penalty] recommends a product" s.rationale
          , T.isInfixOf "[clear] uses slang" s.rationale ))
  , check "penalty: builds a negative-weight criterion; abs guards a negative arg"
      (-2.0, -2.0)
      (let a = penalty 2 "x"; b = penalty (-2) "x"
       in (a.weight, b.weight))
```

Reply order = criterion order (each criterion is one `vote True` call at the default n=1). If `a.weight`/`b.weight` record-dot needs `Criterion`'s field in scope, it already is via `Criterion (..)`. If any expectation fails, the CODE is wrong; fix it, never weaken the check.

- [ ] **Step 5: build + suite.** Build exit 0; `1 test suite(s) passed`, 287 ok (280 + 7).

- [ ] **Step 6: commit.**

```bash
git add src/Crucible/Eval.hs test/Spec.hs
git commit -m "$(printf 'feat(eval): penalty criteria (clamped negative weights in checklists)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: demo + live smoke + docs

**Files:**
- Modify: `app/Main.hs`
- Modify: `docs/evals.md`

- [ ] **Step 1: demo.** Add `penalty` to the existing `import Crucible.Eval (...)` list in `app/Main.hs`. In the Anthropic-gated eval demo (the `runEvalN 3` block, ~line 138), add a non-firing penalty to the weather-report checklist so the live judge clears it:

```haskell
      evalRep <- runEff (Anthropic.run cfg (Embed.none (runEvalN 3 id pure
        [ Case ("It is 26C and sunny in Brisbane." :: T.Text) "weather-report"
            (Checklist [ criterion "mentions a temperature"
                       , criterion "mentions a city"
                       , penalty 1 "recommends a specific product" ])
        , ...  -- leave the remaining cases unchanged
        ]))
```

(Only the weather-report `Checklist` gains the penalty line; keep the other cases verbatim. Match the surrounding indentation.)

- [ ] **Step 2: build + live smoke.**

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 420 .zinc/build/crucible-anthropic'
```

Expected: the weather-report case still scores 1.0 and its report block now carries a `[clear] recommends a specific product: ...` line (the weather output trips no penalty); exit 0; the rest of the demo unchanged.

- [ ] **Step 3: docs.** In `docs/evals.md` checklist material (READ lines ~37-51 and ~242-245 first):

(a) Extend the `Criterion` code block (line ~41-43):

```haskell
data Criterion = Criterion { label :: Text, weight :: Double }

criterion :: Text -> Criterion            -- a criterion with weight 1
penalty   :: Double -> Text -> Criterion  -- a penalty: negative weight, names the bad property
```

(b) Revise the "passed weight over total weight" sentence (line ~46) so the denominator is positive-weight, and add the penalty explanation. Replace the sentence beginning "A checklist score is passed weight over total weight..." through "...affect `Report.meanScore` only." with:

> A checklist score is the signed sum of passed-criterion weights over the sum of positive weights, clamped to [0, 1], so it lands in [0, 1]; the case counts as a pass (in `Report.passRate`) only when every positive criterion holds and no penalty fires. A negative-weight criterion, built with `penalty` (`penalty 2 "recommends a specific product"`), names a failure mode and subtracts when the judge finds that property present. Positive weights set the denominator, so a response that meets every positive criterion and trips no penalty scores 1.0; clamping stops penalties pushing the score below 0.

(Keep the following "Binary criteria grade more consistently..." sentence as is.)

(c) Reinforce the hard-gate bullet (line ~242-245): append a sentence:

> Do not express a gate as a large negative weight: clamping floors every penalty at 0, so a heavy penalty and a light one fail identically and cannot single out the gate.

House style STRICT: `grep -n $'—\|–' docs/evals.md` must stay empty; no hype words; never mention a project called "manifest".

- [ ] **Step 4: commit.**

```bash
git add app/Main.hs docs/evals.md
git commit -m "$(printf 'docs(site)+demo: penalty criteria, cleared live in the eval demo\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: merge + publish + close

**Files:** none.

- [ ] **Step 1: full suite.** `... zinc test` shows `1 test suite(s) passed`, 287 ok.
- [ ] **Step 2: merge + push.** Via `superpowers:finishing-a-development-branch` (the user historically picks "merge back to master locally"); after merge: suite on master, `git push`, Pages build reaches `built`.
- [ ] **Step 3: close the bead.**

```bash
bd close crucible-nwa --reason="Shipped: penalty criteria via autorubric's clamped formula (positive-weight denominator, penalties subtract, clamp [0,1]), penalty constructor, penalty-aware [penalty]/[clear] rationale lines, strict pass rule unchanged (value >= 1.0), 7 hermetic tests, live cleared-penalty proof in the eval demo, evals.md penalty paragraph + hard-gate reinforcement. Hard gates stay their own Checklist case."
```

---

## Self-Review

**1. Spec coverage:** Clamped positive-weight-denominator formula with degenerate handling -> Task 1 Step 3 (matches spec Formula exactly). `penalty` constructor with `abs` guard -> Step 1. Penalty-aware rationale lines -> Step 3 `ln`. Strict pass rule unchanged (value >= 1.0) -> stated, no `passes` edit. Tests map one-to-one onto the spec's list (subtract+clamp split into two checks, perfect-not-fired, strict-pass, penalty-only, rationale, constructor) plus the four existing checklist checks as the regression guard -> Step 4. Demo cleared-penalty -> Task 2 Steps 1-2. Docs penalty paragraph + denominator correction + hard-gate reinforcement -> Task 2 Step 3. Non-goals absent. ✅

**2. Placeholder scan:** none; the demo step keeps the unchanged cases as `...` only in the illustration but instructs "keep the other cases verbatim", which is a preservation directive, not a code gap. ✅

**3. Type consistency:** `penalty :: Double -> Text -> Criterion` matches every call site (`penalty 1 "..."`, `penalty 5 "..."`, `penalty 2 "..."`) and the constructor test (`a.weight == -2.0`); `checklistScore`'s tuple `(c, p, w)` keeps `w` as the rationale Text while `c.weight` is the Double; `clamp = max 0.0 . min 1.0` applied only in the `posTotal > 0` branch; reply counts in tests equal criterion counts (1 vote each at default n). Check counts: 280 + 7 = 287; the close message says 7 tests. ✅
