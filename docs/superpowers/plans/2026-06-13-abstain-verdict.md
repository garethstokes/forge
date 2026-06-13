# Abstain Verdict Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A three-way judge verdict (`Pass | Fail | CannotAssess`) with an explicit `AbstainPolicy`, threaded through the codec, vote loop, score consumption, grounding, rendering, and calibration.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-13-abstain-verdict-design.md` (tracker `crucible-0xl`). The verdict shape change is the foundation (Task 1); consumers update to handle the new `AllAbstained` outcome (Task 2); calibration counts abstentions (Task 3). Legacy `{"why","pass"}` JSON still decodes, so existing scripted replies and cassettes keep working.

**Tech Stack:** Haskell GHC 9.12.2, effectful, autodocodec. The project has NO `-Werror`, so an incomplete-pattern warning compiles. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). Exit 137 = GHC iserv flake, retry once; second 137 = BLOCKED. Judge success by exit status or the pass line, never a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/abstain-verdict` from master; work in place, no worktrees.
- House style: DuplicateRecordFields, NoFieldSelectors, OverloadedRecordDot, prefix-free fields. `(.field)` getter sections resolve only when the record type is fixed; if GHC reports ambiguity (several records share `why`/`pass`), annotate the getter and report. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Read first: `src/Crucible/Eval/Judge.hs` (Verdict/codec/judgeSystem/VoteOutcome/vote/JudgeOpts), `src/Crucible/Codec.hs` (combinators), `src/Crucible/Eval.hs` (voteScore/checklistScore/scoreWith/renderReport), `src/Crucible/Eval/Grounding.hs` (verify), `src/Crucible/Eval/Calibrate.hs` (reportFrom/renderCalibration).
- The suite passes with 287 checks. Legacy `{"why","pass":bool}` scripted replies MUST keep decoding (the codec resolves `verdict` first, falling back to `pass`).
- API keys live in `.env` (gitignored). NEVER print, echo, or cat `.env` or any key value.

---

### Task 1: verdict kind + tolerant codec + vote loop (foundation)

**Files:**
- Modify: `src/Crucible/Codec.hs`
- Modify: `src/Crucible/Eval/Judge.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: `Crucible.Codec` gains `optField` and re-exports `bimapCodec`.** In the `import Autodocodec (...)` list add `bimapCodec` and `optionalFieldWith'`. In the module export list add `optField` and `bimapCodec` (near `object, field, anyValue`). Add the definition near `field`:

```haskell
-- | An optional object field (crucible's optional field), on autodocodec.
optField :: Text -> (o -> Maybe f) -> JSONCodec f -> ObjectCodec o (Maybe f)
optField k getter c = optionalFieldWith' k c .= getter
```

- [ ] **Step 2: Judge.hs verdict types + codec.** Add `enum`, `optField`, `bimapCodec` to the `import Crucible.Codec (...)` list. Add `VerdictKind (..)` and `AbstainPolicy (..)` to the module export list. Replace the `Verdict`/`verdictCodec` block (lines ~48-56) with:

```haskell
-- | A three-way grader verdict. CannotAssess lets the judge abstain when
-- the output lacks the information to judge the criterion, distinct from a
-- considered pass or fail. "why" is first so the verdict is conditioned on
-- the reasoning. Decoding accepts the new {"why","verdict"} shape and
-- legacy {"why","pass"} (true->Pass, false->Fail); a reply with neither
-- fails to parse and drives the repair re-prompt.
data VerdictKind = Pass | Fail | CannotAssess deriving (Eq, Show)

data Verdict = Verdict { why :: Text, kind :: VerdictKind } deriving (Eq, Show)

-- | Intermediate for tolerant decode: a new verdict enum or a legacy pass
-- boolean, resolved to a 'VerdictKind'.
data RawVerdict = RawVerdict
  { why     :: Text
  , verdict :: Maybe VerdictKind
  , pass    :: Maybe Bool
  }

kindCodec :: JSONCodec VerdictKind
kindCodec = enum [("pass", Pass), ("fail", Fail), ("cannot_assess", CannotAssess)]

verdictCodec :: JSONCodec Verdict
verdictCodec = bimapCodec toV fromV $
  object (RawVerdict <$> field    "why"     (.why)     str
                     <*> optField "verdict" (.verdict) kindCodec
                     <*> optField "pass"    (.pass)    bool)
  where
    toV r = case r.verdict <|> fmap boolKind r.pass of
      Just k  -> Right (Verdict r.why k)
      Nothing -> Left "verdict: expected a \"verdict\" or \"pass\" field"
    fromV (Verdict w k) = RawVerdict w (Just k) Nothing
    boolKind b = if b then Pass else Fail
```

- [ ] **Step 3: prompt.** Replace `judgeSystem` (lines ~140-147) with:

```haskell
judgeSystem :: Message
judgeSystem = Message System [text|
  You are a strict grader.
  Reason through each rubric requirement in "why" first, quoting the part of
  the output that satisfies or violates it, then give the verdict.
  Length and style are not criteria unless the rubric says so.
  If a requirement is not demonstrably met, fail it.
  Use "cannot_assess" only when the output genuinely lacks the information to
  judge the criterion, never to avoid a hard call.
  Respond ONLY with JSON {"why": <string>, "verdict": "pass" | "fail" | "cannot_assess"}.|]
```

- [ ] **Step 4: `JudgeOpts` + `AbstainPolicy`.** Replace the `JudgeOpts`/`defaultJudgeOpts` block (lines ~71-80) with:

```haskell
-- | How an all-abstain judgement resolves in a checklist: fail the
-- criterion (the strict default) or drop it from the denominator.
data AbstainPolicy = AbstainFails | AbstainSkips deriving (Eq, Show)

-- | Knobs for a judged evaluation. Future judge options (panels) extend
-- this record rather than adding function variants.
data JudgeOpts = JudgeOpts
  { votes    :: Int             -- ^ samples per judgement (odd; 1 = single call)
  , examples :: [JudgeExample]  -- ^ few-shot examples for Rubric judging
  , abstain  :: AbstainPolicy   -- ^ how a checklist criterion's abstention resolves
  }
  deriving (Eq, Show)

defaultJudgeOpts :: JudgeOpts
defaultJudgeOpts = JudgeOpts { votes = 1, examples = [], abstain = AbstainFails }
```

- [ ] **Step 5: `VoteOutcome` + `vote`.** Replace the `VoteOutcome` block (lines ~174-177) and the `vote` definition (lines ~187-210) with:

```haskell
data VoteOutcome
  = Decided { pass :: Bool, why :: Text, dissent :: Maybe Text, yes :: Int, no :: Int }
  | AllErrored   Text
  | AllAbstained Text   -- ^ no yes/no cast and at least one abstain
  deriving (Eq, Show)

-- | Sample the judge up to @n@ times and majority-vote. Pass/Fail tally as
-- yes/no; CannotAssess consumes an attempt without casting a vote (like an
-- error, but recorded honestly), as does a judge error. Early stopping
-- counts only yes/no. On an exhausted budget with no yes/no votes the
-- outcome is 'AllAbstained' if any sample abstained, else 'AllErrored'. A
-- reached majority is 'Decided', with abstains and errors ignored in the
-- tally. Callers should use odd n; n <= 1 is a single sample.
vote :: (LLM :> es) => Bool -> JudgeOpts -> Text -> Text -> Eff es VoteOutcome
vote earlyStop opts rubric graded = go n' (0, 0) (Nothing, Nothing) Nothing ""
  where
    n'   = max 1 opts.votes
    need = n' `div` 2 + 1

    decideYes (fy, fn) y f = Decided True  (fromMaybe "" fy) fn y f
    decideNo  (fy, fn) y f = Decided False (fromMaybe "" fn) fy y f

    go :: (LLM :> es)
       => Int -> (Int, Int) -> (Maybe Text, Maybe Text) -> Maybe Text -> Text
       -> Eff es VoteOutcome
    go 0 (y, f) firsts firstAbs lastErr
      | y == 0 && f == 0 = pure (maybe (AllErrored lastErr) AllAbstained firstAbs)
      | y > f            = pure (decideYes firsts y f)
      | otherwise        = pure (decideNo firsts y f)
    go k tally@(y, f) firsts@(fy, fn) firstAbs lastErr
      | earlyStop && y >= need = pure (decideYes firsts y f)
      | earlyStop && f >= need = pure (decideNo firsts y f)
      | otherwise = do
          r <- judgeOnce opts.examples rubric graded
          case r of
            Left (JudgeError m) -> go (k - 1) tally firsts firstAbs m
            Right v -> case v.kind of
              Pass         -> go (k - 1) (y + 1, f) (fy <|> Just v.why, fn) firstAbs lastErr
              Fail         -> go (k - 1) (y, f + 1) (fy, fn <|> Just v.why) firstAbs lastErr
              CannotAssess -> go (k - 1) tally firsts (firstAbs <|> Just v.why) lastErr
```

- [ ] **Step 6: migrate broken test sites in `test/Spec.hs`.** The `JudgeOpts` arity change breaks two positional constructions; add the third field:
  - line ~1185: `judgeWith (JudgeOpts 1 [JudgeExample "e" True Nothing] AbstainFails)`
  - line ~1193: `runEvalWith (JudgeOpts 1 [JudgeExample "e" True Nothing] AbstainFails)`
  Extend the `Crucible.Eval.Judge` import (line 39) with `VerdictKind(..)`, `AbstainPolicy(..)`, `VoteOutcome(..)`, `vote`. Replace the verdict-codec check (lines ~984-987) with:

```haskell
  , check "verdict codec: new enum, legacy pass bool, and cannot_assess decode"
      (Right Pass, Right Pass, Right Fail, Right CannotAssess)
      ( fmap (.kind) (decodeLLM verdictCodec "{\"why\":\"w\",\"verdict\":\"pass\"}")
      , fmap (.kind) (decodeLLM verdictCodec "{\"pass\":true,\"why\":\"w\"}")
      , fmap (.kind) (decodeLLM verdictCodec "{\"why\":\"w\",\"pass\":false}")
      , fmap (.kind) (decodeLLM verdictCodec "{\"why\":\"w\",\"verdict\":\"cannot_assess\"}") )
  , check "verdict codec: a reply with neither verdict nor pass fails to parse"
      True
      (case decodeLLM verdictCodec "{\"why\":\"w\"}" of
         Left _ -> True
         Right (_ :: Verdict) -> False)
```

(`"{\"why\":\"w\"}"` is well-formed JSON missing both `verdict` and `pass`, so resolution fails and the repair path would fire.) Then add new feature tests after the verdict-codec checks:

```haskell
  , check "vote: all samples abstain yields AllAbstained"
      True
      (case runPureEff (runLLMScripted
              (replicate 3 "{\"why\":\"cant tell\",\"verdict\":\"cannot_assess\"}")
              (vote False (defaultJudgeOpts { votes = 3 }) "r" "out")) of
         AllAbstained m -> T.isInfixOf "cant tell" m
         _              -> False)
  , check "vote: a yes/no majority amid abstains still decides"
      (True, 2, 0)
      (case runPureEff (runLLMScripted
              [ "{\"why\":\"a\",\"verdict\":\"pass\"}"
              , "{\"why\":\"b\",\"verdict\":\"cannot_assess\"}"
              , "{\"why\":\"c\",\"verdict\":\"pass\"}" ]
              (vote False (defaultJudgeOpts { votes = 3 }) "r" "out")) of
         Decided p _ _ y f -> (p, y, f)
         _                 -> (False, 0, 0))
```

- [ ] **Step 7: build + suite.** Build exit 0 (Eval/Grounding/Calibrate will emit incomplete-pattern warnings for the new `AllAbstained` constructor; this is EXPECTED and resolved in Tasks 2-3 — no existing test produces an abstain through those paths, so the suite stays green). `1 test suite(s) passed`, 290 ok (287 - 1 replaced + 4 new = 290).

- [ ] **Step 8: commit.**

```bash
git add src/Crucible/Codec.hs src/Crucible/Eval/Judge.hs test/Spec.hs
git commit -m "$(printf 'feat(judge): three-way verdict (CannotAssess) + AbstainPolicy, tolerant codec\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: score consumption + grounding + rendering

**Files:**
- Modify: `src/Crucible/Eval.hs`
- Modify: `src/Crucible/Eval/Grounding.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: `voteScore`** (Eval.hs). Add an `AllAbstained` equation (policy-independent: a standalone judgement has no denominator to skip):

```haskell
voteScore _      (AllAbstained m)    = score 0.0 ("judge abstained: " <> m)
```

(Place it beside the existing `voteScore _ (AllErrored m) = ...` equation.)

- [ ] **Step 2: `checklistScore`** (Eval.hs). It now takes the policy and resolves each criterion to a `Maybe Bool` (Nothing = skipped). Replace the whole definition with:

```haskell
-- | Judge each criterion with its own binary call; positive weights set the
-- denominator, penalties subtract, the score clamps to [0,1]. An abstained
-- criterion fails (and stays in the denominator) under 'AbstainFails', or
-- drops from the denominator under 'AbstainSkips'. A judge error fails the
-- criterion. value reaches 1.0 only when every positive criterion passes
-- and no penalty fires.
checklistScore :: (LLM :> es) => Int -> AbstainPolicy -> (a -> Text) -> [Criterion] -> a -> Eff es Score
checklistScore _ _ _ [] _ = pure (score 1.0 "empty checklist")
checklistScore n pol render cs actual = do
  rs <- mapM judge1 cs
  let posTotal = sum [c.weight | (c, m, _) <- rs, c.weight > 0, m /= Nothing]
      got      = sum [c.weight | (c, Just True, _) <- rs]
      clamp    = max 0.0 . min 1.0
      val | posTotal > 0 = clamp (got / posTotal)
          | got < 0      = 0.0
          | otherwise    = 1.0
  pure (score val (T.intercalate "\n" [ l | (_, _, l) <- rs ]))
  where
    judge1 c = do
      out <- vote True defaultJudgeOpts { votes = n } ("the output must satisfy: " <> c.label) (render actual)
      pure $ case out of
        Decided p w _ _ _ -> (c, Just p,     decidedLine c p w)
        AllErrored m      -> (c, Just False, "[fail] "    <> c.label <> ": judge error: " <> m)
        AllAbstained m    -> case pol of
          AbstainFails -> (c, Just False, "[abstain] " <> c.label <> ": judge abstained: " <> m)
          AbstainSkips -> (c, Nothing,    "[skip] "    <> c.label <> ": judge abstained: " <> m)
    decidedLine c p w
      | c.weight < 0 = (if p then "[penalty] " else "[clear] ") <> c.label <> ": " <> w
      | otherwise    = (if p then "[pass] "    else "[fail] ")  <> c.label <> ": " <> w
```

Update the call site in `scoreWith`: `Checklist cs -> checklistScore opts.votes opts.abstain render cs actual`.

- [ ] **Step 3: `renderReport`** (Eval.hs). Add a `[judge abstained]` annotation distinct from `[judge error]`. In the `annot`/`jerr` area add:

```haskell
    jabs s = if "judge abstained: " `T.isInfixOf` s.rationale then "  [judge abstained]" else ""
```

and include `jabs s` in the `annot s = ...` concatenation (alongside `jerr s`).

- [ ] **Step 4: grounding** (Grounding.hs). Add the `AllAbstained` case to `verify` (lines ~80-82):

```haskell
        AllAbstained m    -> (claim, False, "judge abstained: " <> m)
```

(An abstained claim is unsupported with the abstained tag; no policy for derived claims.)

- [ ] **Step 5: tests** (test/Spec.hs). Add after the Task 1 vote tests:

```haskell
  , check "abstain: a standalone rubric abstain scores 0 with the abstained tag"
      (0.0, True)
      (let s = runPureEff (runLLMScripted ["{\"why\":\"no info\",\"verdict\":\"cannot_assess\"}"]
                 (judge id "r" ("out" :: Text)))
       in (s.value, T.isInfixOf "judge abstained: " s.rationale))
  , check "abstain: AbstainFails keeps an abstained positive criterion in the denominator"
      True
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"y\",\"verdict\":\"pass\"}"
                 , "{\"why\":\"no info\",\"verdict\":\"cannot_assess\"}" ]
                 (Embed.none (scoreM id (Checklist [criterion "a", criterion "b"]) ("out" :: Text))))
       in abs (s.value - 0.5) < 1e-9)
  , check "abstain: AbstainSkips drops an abstained criterion from the denominator"
      (1.0, True)
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"y\",\"verdict\":\"pass\"}"
                 , "{\"why\":\"no info\",\"verdict\":\"cannot_assess\"}" ]
                 (Embed.none (scoreWith (defaultJudgeOpts { abstain = AbstainSkips }) id
                    (Checklist [criterion "a", criterion "b"]) ("out" :: Text))))
       in (s.value, T.isInfixOf "[skip] b" s.rationale))
  , check "abstain: a penalty abstain clears under AbstainFails"
      1.0
      ((runPureEff (runLLMScripted
         [ "{\"why\":\"y\",\"verdict\":\"pass\"}"
         , "{\"why\":\"no info\",\"verdict\":\"cannot_assess\"}" ]
         (Embed.none (scoreM id (Checklist [criterion "a", penalty 1 "recommends a product"]) ("out" :: Text))))).value)
  , check "renderReport: abstained case is annotated distinctly from judge error"
      (True, False)
      (let rep = runPureEff (runLLMScripted ["{\"why\":\"no info\",\"verdict\":\"cannot_assess\"}"]
                   (Embed.none (runEval id pure [Case ("x" :: Text) "a" (Rubric "r")])))
           t = renderReport rep
       in (T.isInfixOf "[judge abstained]" t, T.isInfixOf "[judge error]" t))
```

`scoreWith`, `penalty`, `judge` arrive via the existing `Crucible.Eval` import (add any missing to that import list). The AbstainFails checklist test: a=pass (1), b=abstain→fail, posTotal=2, got=1 → 0.5. The AbstainSkips test: b drops, posTotal=1, got=1 → 1.0. The penalty test: a=pass (1), penalty abstain→clears (met Just False, not fired), posTotal=1, got=1 → 1.0.

- [ ] **Step 6: build + suite.** Build exit 0 (no more incomplete-pattern warnings for VoteOutcome in Eval/Grounding); `1 test suite(s) passed`, 295 ok (290 + 5).

- [ ] **Step 7: commit.**

```bash
git add src/Crucible/Eval.hs src/Crucible/Eval/Grounding.hs test/Spec.hs
git commit -m "$(printf 'feat(eval): consume the abstain verdict (policy, skip, distinct rendering)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: calibration counts abstentions

**Files:**
- Modify: `src/Crucible/Eval/Calibrate.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: `CalibrationReport` field.** Append a final field to the record (after `kappaCI`):

```haskell
  , kappaCI       :: (Double, Double)  -- ^ 95% bootstrap interval for kappa
  , abstained     :: [Text]            -- ^ case names where the judge abstained
  }
```

- [ ] **Step 2: `reportFrom`.** Add the abstain list and pass it to the constructor:

```haskell
reportFrom seed outcomes exampleCount_ measured_ =
  CalibrationReport po kap fPrec fRec cont errs exampleCount_ measured_ ci abst
  where
    errs   = [nm | (nm, _, AllErrored _) <- outcomes]
    abst   = [nm | (nm, _, AllAbstained _) <- outcomes]
    judged = [(nm, h, p, y, f) | (nm, h, Decided p _ _ y f) <- outcomes]
    ...  -- the rest unchanged
```

(`judged` already excludes both errors and abstains, so agreement/kappa skip abstained cases automatically.)

- [ ] **Step 3: `renderCalibration`.** Add an abstained line after the judge-errors line (line ~148):

```haskell
  ++ [ "judge abstained: " <> T.intercalate ", " r.abstained | not (null r.abstained) ]
```

- [ ] **Step 4: migrate `CalibrationReport` positional constructions in `test/Spec.hs`** (the new final field). Append `[]` to each (lines ~1137, ~1197, ~1234, ~1237-1238):
  - `CalibrationReport 1.0 0 1.0 1.0 [] [] 0 2 (0, 0) []`
  - `CalibrationReport 1.0 0 1.0 1.0 [] [] 2 2 (0, 0) []`
  - `CalibrationReport 1 0 1 1 [] [] 0 4 (0, 0) []`
  - the `withEx`/`withoutEx` pair likewise gain a trailing `[]`.

- [ ] **Step 5: new calibrate test.** Add near the other calibrate checks:

```haskell
  , check "calibrate: an abstained case is listed separately and excluded from kappa"
      (["b"], 1)
      (let r = runPureEff (runLLMScripted
                 [ "{\"why\":\"\",\"verdict\":\"pass\"}"        -- case a: judged
                 , "{\"why\":\"\",\"verdict\":\"cannot_assess\"}" ] -- case b: abstains
                 (calibrate 0 id "r"
                    [ ("a", "o1" :: Text, True), ("b", "o2", True) ]))
       in (r.abstained, r.measured))
```

(Both cases are holdout, no examples; case a agrees, case b abstains. `abstained = ["b"]`; `measured` is the holdout count = 2... adjust the expectation to the real `measured` after one run if it differs, and report. The load-bearing assertion is `r.abstained == ["b"]`.)

- [ ] **Step 6: build + suite.** `1 test suite(s) passed`, 296 ok (295 + 1).

- [ ] **Step 7: commit.**

```bash
git add src/Crucible/Eval/Calibrate.hs test/Spec.hs
git commit -m "$(printf 'feat(eval): calibrate counts abstentions separately from disagreement\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 4: demo + live smoke + docs

**Files:**
- Modify: `app/Main.hs`
- Modify: `docs/evals.md`

- [ ] **Step 1: demo.** In the Anthropic-gated block, add one Rubric whose criterion asks about a property the output cannot speak to, to provoke a live abstain, and print its annotated report line. After the lint demo (or near the eval demo), add:

```haskell
      abstainRep <- runEff (Anthropic.run cfg (Embed.none (runEval id pure
        [ Case ("The meeting is at 3pm." :: T.Text) "off-topic-criterion"
            (Rubric "the output correctly cites the source's publication date") ])))
      TIO.putStrLn (renderReport abstainRep)
```

- [ ] **Step 2: build + live smoke.**

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 420 .zinc/build/crucible-anthropic'
```

Expected: a report line for `off-topic-criterion`; if the live judge abstains it carries `[judge abstained]` and scores 0. If the model instead fails it (some models will not abstain), the path is still exercised hermetically by the suite; REPORT which happened. Do not weaken anything. exit 0.

- [ ] **Step 3: docs.** In `docs/evals.md` (judging material): document the three-way verdict (`cannot_assess`), the `AbstainPolicy` (`AbstainFails` default; `AbstainSkips` drops the criterion from the checklist denominator), that a standalone Rubric/Scale abstain fails (scores 0), that a penalty abstain clears under `AbstainFails`, that abstention renders as `[judge abstained]` distinct from `[judge error]`, and that `calibrate` lists abstentions separately and excludes them from agreement/kappa. If the `JudgeOpts` record is shown anywhere on the page, add the `abstain` field. House style STRICT: `grep -n $'—\|–' docs/evals.md` empty; no hype; no "manifest".

- [ ] **Step 4: commit.**

```bash
git add app/Main.hs docs/evals.md
git commit -m "$(printf 'docs(site)+demo: abstain verdict, shown live\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 5: merge + publish + close

**Files:** none.

- [ ] **Step 1: full suite.** `... zinc test` shows `1 test suite(s) passed`, 296 ok.
- [ ] **Step 2: merge + push.** Via `superpowers:finishing-a-development-branch`; after merge: suite on master, `git push`, Pages build reaches `built`.
- [ ] **Step 3: close the bead.**

```bash
bd close crucible-0xl --reason="Shipped: three-way judge verdict (Pass|Fail|CannotAssess) with AbstainPolicy (AbstainFails default | AbstainSkips), tolerant codec (legacy {why,pass} still decodes), vote AllAbstained, standalone-abstain-fails + checklist skip/fail + penalty-abstain-clears, [judge abstained] rendering distinct from [judge error], calibrate counts abstentions separately, ~9 tests, live abstain demo. Scale-abstain and pessimistic-penalty-abstain remain non-goals."
```

---

## Self-Review

**1. Spec coverage:** VerdictKind/Verdict + tolerant codec (verdict enum + legacy pass, both-absent fails) -> Task 1 Steps 1-2. Prompt guard -> Step 3. AbstainPolicy on JudgeOpts (default AbstainFails) -> Step 4. vote AllAbstained semantics -> Step 5. voteScore standalone-abstain (Q3) -> Task 2 Step 1. checklistScore policy/skip/tags with penalty interaction (Q4 literal) -> Step 2. renderReport [judge abstained] -> Step 3. grounding abstain -> Step 4. calibrate abstained field + exclusion + render -> Task 3. Demo + docs -> Task 4. Tests map onto the spec's testing list (codec, vote, standalone, checklist fail/skip, penalty clear, render, calibrate). Non-goals (Scale abstain, pessimistic penalty, standalone exclusion, grounding policy) absent. ✅

**2. Placeholder scan:** none; the both-absent codec string is corrected to `"{\"why\":\"w\"}"` in Step 6; the calibrate `measured` expectation is flagged as pin-after-run with the load-bearing assertion named. ✅

**3. Type consistency:** `Verdict { why, kind }` with `kind :: VerdictKind`; vote reads `v.kind`/`v.why`; `VoteOutcome` three constructors handled in voteScore, checklistScore.judge1, grounding.verify, calibrate.reportFrom (all four consumers updated by Task 3's end; Task 1 leaves them warning-only, no -Werror); `JudgeOpts` third field `abstain` threads via `opts.abstain` to checklistScore; `checklistScore :: Int -> AbstainPolicy -> ...` matches its scoreWith call; `CalibrationReport` final field `abstained :: [Text]` matches the positional constructor `... ci abst` and the four migrated test constructions. Check counts: 287 -1 +4 (T1) = 290; +5 (T2) = 295; +1 (T3) = 296. ✅
