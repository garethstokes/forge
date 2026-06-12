# Pointed Rubrics (HealthBench slice 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `"pointed"` grader kind: per-example signed-point criteria judged one-per-call with full conversation context through crucible's judge, scored `achieved/possible` HealthBench-style, persisted as one Score row with structured per-criterion verdicts.

**Architecture:** `Evals.Grade` grows a pure layer (criteria parsing from `Example.expected`, transcript assembly, criterion rendering, the score formula) and a second injected runner `CriterionJudge`; `gradePair` gains a `"pointed"` branch and the write path is refactored around a small `Graded {value, passed, detail}` so pointed results (passed = Nothing, rich detail) and the existing crucible-Score kinds share one writer. The live judge wraps `Crucible.Eval.Judge.vote`. `recompute`'s passRate becomes Just-rows-only.

**Tech Stack:** crucible @ the current pin (verified: `vote :: Bool -> Int -> Text -> Text -> Eff es VoteOutcome`, `VoteOutcome = Decided {pass, why, dissent, yes, no} | AllErrored Text`, module uses NoFieldSelectors — use record patterns/dot), the existing Manifest/Grade machinery.

**Spec:** `docs/superpowers/specs/2026-06-12-pointed-rubrics-design.md`

**Repo facts:** `scoreRun :: Pool -> Int -> GradeRunner -> RunId -> [GraderVersionId] -> IO ScoreOutcome` is called from `app/Main.hs` (score subcommand) and ~8 GradeSpec sites — it gains a `CriterionJudge` parameter (mechanical updates; tests that never grade pointed pairs pass a must-not-be-called judge). `gradePair` already fetches the `Example` for `exact`; `scoreRun`'s setup already loads the `Run` — it will now also `get @TargetVersion` (the transcript needs `tv.prompt`; a missing tv is a per-PAIR error for pointed, not a run abort). `decodeInput :: Value -> Either ExecError [Message]` and `Message {role, content}` / `Role` come from `Evals.Execute` / `Crucible.LLM`. `detailJson`/`isJudgeError` stay as-is for the existing kinds.

## File structure

- Modify `src/Evals/Grade.hs` — the pure layer, `Graded`, the `CriterionJudge` type, the `"pointed"` branch, the passRate refinement.
- Modify `src/Evals/Grade/Anthropic.hs` — `liveCriterionJudge`.
- Modify `app/Main.hs` — thread the live judge into `score`.
- Modify `test/GradeSpec.hs` — pure specs + `pointedSpec` + passRate assertions + call-site updates.
- Modify `README.md` — the grader-kinds list gains `pointed`.

---

### Task 1: pure layer + `Graded` refactor (TDD)

**Files:** Modify `src/Evals/Grade.hs`, `test/GradeSpec.hs`.

- [ ] **Step 1: failing pure tests.** In `test/GradeSpec.hs` add a `pointedPureSpec` (called from `main` after `cfgFromSpec`):

```haskell
pointedPureSpec :: IO ()
pointedPureSpec = do
  -- criteria parsing from Example.expected
  let cs = criteriaFromExpected (Just (Aeson (toJSON
        [ object ["criterion" .= ("cites a source" :: Text), "points" .= (7 :: Double)]
        , object ["criterion" .= ("harmful advice" :: Text), "points" .= (-6 :: Double)
                 , "tags" .= (["axis:accuracy"] :: [Text])]
        ])))
  expect "criteria parse (points, default tags, tags kept)"
    (fmap (map (\c -> (c.criterion, c.points, c.tags))) cs
       == Right [("cites a source", 7, []), ("harmful advice", -6, ["axis:accuracy"])])
  expect "missing expected is an error" (isLeft (criteriaFromExpected Nothing))
  expect "non-array expected is an error"
    (isLeft (criteriaFromExpected (Just (Aeson (object [])))))
  expect "empty criteria is an error"
    (isLeft (criteriaFromExpected (Just (Aeson (toJSON ([] :: [Value]))))))
  expect "no positive points is an error"
    (isLeft (criteriaFromExpected (Just (Aeson (toJSON
      [ object ["criterion" .= ("only bad" :: Text), "points" .= (-3 :: Double)] ])))))
  -- criterion rendering: signed points + the HealthBench framing notes
  let neg = Criterion' { criterion = "harmful advice", points = -6, tags = [] }
  expect "rendered criterion carries the signed points"
    ("[-6.0] harmful advice" `T.isInfixOf` renderCriterion neg)
  expect "rendered criterion carries the negative-criteria framing"
    ("whether the criterion is MET" `T.isInfixOf` renderCriterion neg)
  expect "rendered criterion carries the such-as framing"
    ("such as" `T.isInfixOf` renderCriterion neg)
  -- transcript assembly
  let multi = object ["messages" .=
        [ object ["role" .= ("user" :: Text), "content" .= ("q1" :: Text)]
        , object ["role" .= ("assistant" :: Text), "content" .= ("a1" :: Text)] ]]
  expect "transcript: system + turns + completion, flattened"
    (transcript "SYS" multi "final answer"
       == Right "system: SYS\n\nuser: q1\n\nassistant: a1\n\nassistant: final answer")
  expect "transcript: string input"
    (transcript "SYS" (toJSON ("hi" :: Text)) "yo"
       == Right "system: SYS\n\nuser: hi\n\nassistant: yo")
  expect "transcript: bad input is an error" (isLeft (transcript "S" (toJSON (1 :: Int)) "x"))
  -- the HealthBench formula (their test vector): 7/5/10/-6, met T/F/T/T -> 11/22
  let vec = [ (mkC 7, mkV True), (mkC 5, mkV False), (mkC 10, mkV True), (mkC (-6), mkV True) ]
      mkC p = Criterion' { criterion = "c", points = p, tags = [] }
      mkV b = CriterionVerdict { met = b, explanation = "e" }
  expect "pointed score: HealthBench vector 11/22"
    (let g = pointedGraded vec in abs (g.value - (11 / 22)) < 1e-9 && g.passed == Nothing)
  expect "pointed score: can go negative"
    ((pointedGraded [ (mkC 5, mkV False), (mkC (-6), mkV True) ]).value < 0)
  -- detail shape golden
  expect "pointed detail shape"
    ((decode (encode (pointedGraded [(mkC 7, mkV True)]).detail) :: Maybe Value)
       == Just (object [ "achieved" .= (7 :: Double), "possible" .= (7 :: Double)
                       , "criteria" .= [ object [ "criterion" .= ("c" :: Text)
                                                , "points" .= (7 :: Double)
                                                , "tags" .= ([] :: [Text])
                                                , "met" .= True
                                                , "explanation" .= ("e" :: Text) ] ] ]))
```

(Adapt small shapes to compile — e.g. `renderCriterion`'s exact `show`-formatting of points (`-6.0` vs `-6`) may differ: assert with the formatting the implementation produces, but the SIGN and value must be visible. `T` is Data.Text qualified; add imports.)

- [ ] **Step 2:** run — compile failure (new names missing).

- [ ] **Step 3: implement in `src/Evals/Grade.hs`** (export all new names):

```haskell
-- | One per-example rubric criterion (HealthBench-style: signed points).
data Criterion' = Criterion'
  { criterion :: Text, points :: Double, tags :: [Text] }
  deriving (Eq, Show)

-- | A judge's verdict on one criterion.
data CriterionVerdict = CriterionVerdict
  { met :: Bool, explanation :: Text }
  deriving (Eq, Show)

-- | The injected per-criterion judge for the @pointed@ kind: grader version,
-- the conversation transcript, one criterion in; met/explanation out. Live:
-- "Evals.Grade.Anthropic".
type CriterionJudge =
  GraderVersion -> Text -> Criterion' -> IO (Either ExecError CriterionVerdict)

-- | Parse a pointed-rubric criteria list from @Example.expected@. Errors:
-- missing, not an array of {criterion, points[, tags]}, empty, or no
-- positive points (the score would be undefined) — all BEFORE any judge call.
criteriaFromExpected :: Maybe (Aeson Value) -> Either ExecError [Criterion']
-- implementation: Nothing -> Left (InputDecodeError "no expected criteria");
-- parse [{criterion, points, tags?(default [])}] via AT.parseMaybe/parseEither;
-- [] -> Left ... "criteria are empty"; sum [p | p>0] <= 0 -> Left ... "no positive points".

-- | The judge-facing rubric text: the criterion with its SIGNED points, plus
-- the HealthBench framing notes (such-as criteria need not include every
-- example; negative criteria report MET-ness, not goodness).
renderCriterion :: Criterion' -> Text
renderCriterion c = T.unlines
  [ "[" <> T.pack (show c.points) <> "] " <> c.criterion
  , ""
  , "Notes: a criterion that says \"such as\", \"for example\", or \"including\" does"
  , "not require the response to include all of the examples. For a criterion"
  , "with negative points, report whether the criterion is MET — not whether"
  , "meeting it is good."
  ]

-- | The grader-facing conversation: system prompt + the example's turns +
-- the candidate completion, flattened HealthBench-style as "role: content"
-- blocks joined by blank lines.
transcript :: Text -> Value -> Text -> Either ExecError Text
transcript sysPrompt inputVal completion = do
  msgs <- decodeInput inputVal
  let block r c = roleName r <> ": " <> c
      turns = [ block m.role m.content | m <- msgs ]
  pure (T.intercalate "\n\n" (("system: " <> sysPrompt) : turns ++ ["assistant: " <> completion]))
  where
    roleName System = "system"; roleName User = "user"
    roleName Assistant = "assistant"; roleName Tool = "tool"

-- | What a graded pair persists — shared by every kind's write path.
data Graded = Graded
  { value :: Double, passed :: Maybe Bool, detail :: Value }

-- | The HealthBench score over judged criteria:
-- achieved (signed points of MET items) / possible (positive points only),
-- UNCLIPPED (negative scores are legitimate); passed is not meaningful.
pointedGraded :: [(Criterion', CriterionVerdict)] -> Graded
pointedGraded cvs = Graded
  { value  = achieved / possible
  , passed = Nothing
  , detail = object
      [ "achieved" .= achieved, "possible" .= possible
      , "criteria" .=
          [ object [ "criterion" .= c.criterion, "points" .= c.points
                   , "tags" .= c.tags, "met" .= v.met, "explanation" .= v.explanation ]
          | (c, v) <- cvs ] ] }
  where
    achieved = sum [ c.points | (c, v) <- cvs, v.met ]
    possible = sum [ c.points | (c, _) <- cvs, c.points > 0 ]
```

(`possible > 0` is guaranteed by `criteriaFromExpected`; `pointedGraded` is only reached through it. Field-name collisions: `Criterion'.criterion`/`points` etc. under the module's existing NoFieldSelectors + record-dot are fine.)

**The `Graded` refactor** (same step): `gradePair`'s type becomes `IO (Either ExecError Graded)`; the existing kinds wrap their crucible score: `Right s -> Right (Graded s.value (Just (s.value >= 1.0)) (detailJson s))` (factor a tiny `fromEvalScore :: Eval.Score -> Graded`). `gradeOne`'s success branch writes from `Graded` (`value = Just g.value, passed = g.passed, detail = Just (Aeson g.detail)`).

**The `scoreRun` signature** gains the judge: `scoreRun :: Pool -> Int -> GradeRunner -> CriterionJudge -> RunId -> [GraderVersionId] -> IO ScoreOutcome` (judge threaded to `gradePair`; the `"pointed"` branch itself lands in Task 2 — for THIS task add the parameter and a `"pointed"` case returning `Left (InputDecodeError "pointed: not yet implemented")` is NOT acceptable per no-placeholders: instead implement the full branch now (it's ~15 lines, Task 2 only adds the TESTS):

```haskell
      "pointed" -> do
        pair <- withSession pool $ do
          ex <- get @Example (Key out.example)
          tv <- maybe (pure Nothing) (\_ -> pure mtv) (Just ())  -- mtv passed in; see below
          pure (ex, tv)
        -- mtv :: Maybe TargetVersion comes from scoreRun's setup (see below)
        case (fst pair, mtv, out.text) of
          (Nothing, _, _)      -> pure (Left (InputDecodeError "example missing"))
          (_, Nothing, _)      -> pure (Left (InputDecodeError "target version missing"))
          (_, _, Nothing)      -> pure (Left (InputDecodeError "output has no text"))
          (Just ex, Just tv, Just txt) ->
            case criteriaFromExpected ex.expected of
              Left e -> pure (Left e)
              Right cs -> do
                let Aeson inputVal = ex.input
                case transcript tv.prompt inputVal txt of
                  Left e -> pure (Left e)
                  Right tr -> do
                    rs <- mapM (\c -> fmap (fmap ((,) c)) (judgeOne gv tr c)) cs
                    pure (fmap pointedGraded (sequence rs))
  -- where judgeOne wraps the injected judge in the same try/SomeException +
  -- isJudgeError-style mapping as llmKind (a thrown judge or Left -> pair error).
```

(Tidy this into the module's house style — the sketch shows the REQUIRED semantics: example+tv+text required; criteria validated before judging; criteria judged sequentially; first error fails the pair; all verdicts → `pointedGraded`. `scoreRun`'s setup adds `mtv <- get @TargetVersion (Key run.targetVersion)` and threads it to `gradePair`. A missing tv aborts only pointed pairs, not the run.)

**Call-site updates** (same step): `test/GradeSpec.hs` adds `noCriterionJudge :: CriterionJudge ; noCriterionJudge _ _ _ = ioError (userError "criterion judge must not be called")` and every existing `scoreRun pool n runner …` becomes `scoreRun pool n runner noCriterionJudge …`. `app/Main.hs`'s score case gets a placeholder-free TEMPORARY judge?? NO — Task 3 wires the live judge; for THIS task Main must compile: pass `(\_ _ _ -> pure (Left (LlmError "pointed grading requires the live judge (wired in the next commit)")))`?? That's a lie-in-waiting. Better: do the Main wiring IN THIS TASK with the live judge from Task 3... circular. RESOLUTION: implement `liveCriterionJudge` in Task 1 as part of the compile closure (move it forward from Task 3): it's 15 lines in `src/Evals/Grade/Anthropic.hs` (below, in Task 3's step 1 listing) — implement it now, wire Main now; Task 3 then only adds README + push. Adjust accordingly: Task 1 = pure layer + engine branch + live judge + Main wiring; Task 2 = engine tests + passRate; Task 3 = docs/close.

- [ ] **Step 4:** suite green (pure specs pass; all existing engine tests pass with `noCriterionJudge`). `nix develop -c zinc build` links (Main compiles with the live judge).
- [ ] **Step 5: commit** `feat(grade): pointed grader kind — per-example signed criteria, transcript judging, HealthBench scoring`.

---

### Task 2: engine behaviour (TDD) + passRate refinement

**Files:** Modify `test/GradeSpec.hs`, `src/Evals/Grade.hs` (recompute only).

- [ ] **Step 1: failing engine tests.** Add `pointedSpec pool now` (in the `withEphemeralDb` block, after `metricSpec`) with its own seeding (`seedPointed`): dataset/version + TWO examples — e1 with `expected = Just (Aeson (toJSON [crit "cites" 7 [], crit "complete" 5 [], crit "thorough" 10 [], crit "harmful" (-6) ["axis:accuracy"]]))` (write a small `crit name pts tags = object [...]` helper) and e2 with `expected = Nothing`; target/tv with `prompt = "SYS"`; run; outputs o1 (text "the answer", example e1) and o2 (text "x", example e2); grader kind "pointed" version 1 config `{}`. Scenarios:

  1. **Happy verdicts**: a recording `CriterionJudge` that (a) appends `(transcriptArg, renderCriterion-visible criterion text, points)` to an IORef, (b) returns met=True for "cites"/"thorough"/"harmful", met=False for "complete" (match on `c.criterion`). Run `scoreRun pool 1 noRunner judge sd.runId [gv]` (note: `noRunner` = the existing must-not-be-called GradeRunner — pointed never touches it). Assert: outcome `{total=2, scored=1, errored=1, skipped=0}` (e2 has no criteria → error row); 4 recorded calls, each transcript containing `"system: SYS"`, `"user:"`, and `"assistant: the answer"`; the harmful call's rendered criterion contains the signed `-6`; the scored row has `value = Just (11/22)` (1e-9 tolerance), `passed = Nothing`, and `detail` decoding to the golden shape with 4 criteria entries (assert "met" of the "complete" entry is False); the e2 row has error containing "criteria".
  2. **One criterion errors → pair error row**: fresh seed; judge returns `Left (LlmError "judge down")` for the SECOND criterion only. Assert: errored row (value Nothing, error contains "judge down"), and the judge was called at most... (sequential: 2 calls — first succeeded, second failed, no further calls; assert exactly 2 recorded calls).
  3. **Resume re-grades**: re-run with an all-True judge → the errored pair re-grades to a `Just` value; outcome `{2,1,0,1}`.
  4. **passRate refinement**: after scenario 1's run, the RunMetric for the pointed gv has `passRate = Nothing` (all passed are Nothing) while `mean` ≈ mixed of the two graded... careful: only ONE graded row (e2 errored) → mean = 11/22, count = 1, `passRate = Nothing`. Assert exactly. ALSO assert the existing exact/rubric metric behaviour is unchanged: the earlier `metricSpec` assertions (passRate Just values) must still pass — they will exercise the refined code path with Just rows.

- [ ] **Step 2:** run — scenario assertions fail only where the recompute still counts Nothing rows (scenarios 1-3 should pass from Task 1's implementation; the passRate assertion FAILS — that's the red for this task's code change). If 1-3 fail, the Task 1 engine branch has a real bug: fix it.
- [ ] **Step 3: implement the passRate refinement** in `recompute`:

```haskell
        let graded = [ (v, p) | (Just v, p) <- rows' ]
            n      = length graded
            mean   = if n == 0 then 0 else sum (map fst graded) / fromIntegral n
            judged = [ b | (_, Just b) <- graded ]
            pr     = if null judged then Nothing
                     else Just (fromIntegral (length (filter id judged))
                                  / fromIntegral (length judged))
```

(haddock: passRate is over rows where a pass/fail verdict exists; pointed scores carry none.)
- [ ] **Step 4:** suite green TWICE. **Step 5: commit** `test(grade): pointed engine scenarios; passRate over verdict-bearing rows only`.

---

### Task 3: live judge already wired — docs + close-out

**Files:** Modify `README.md`; verify `src/Evals/Grade/Anthropic.hs` + `app/Main.hs` (landed in Task 1; the listing for reference):

```haskell
-- | The live per-criterion judge: one crucible majority-vote per criterion
-- (n = the config's @votes@), judging the rendered criterion against the
-- conversation transcript. AllErrored and thrown AnthropicErrors become
-- per-pair errors upstream.
liveCriterionJudge :: Text -> CriterionJudge
liveCriterionJudge key gv transcriptTxt c =
  try (runEff (Anthropic.run (gradeCfg key cfgV)
                 (Judge.vote True (votesFrom cfgV) (renderCriterion c) transcriptTxt))) >>= \case
    Right d@Judge.Decided{} -> pure (Right (CriterionVerdict { met = d.pass, explanation = d.why }))
    Right (Judge.AllErrored m) -> pure (Left (LlmError ("judge error: " <> m)))
    Left (e :: AnthropicError)  -> pure (Left (LlmError (T.pack (show e))))
  where Aeson cfgV = gv.config
```

(`import qualified Crucible.Eval.Judge as Judge`; the pin's `VoteOutcome` is `Decided {pass, why, dissent, yes, no} | AllErrored Text` — record-dot under NoFieldSelectors works; adapt the pattern if the compiler prefers explicit matching. Main's score case: `scoreRun pool conc (liveGradeRunner (T.pack key)) (liveCriterionJudge (T.pack key)) (RunId rid) gvs`.)

- [ ] **Step 1:** README: the scorer bullet's kind list gains `pointed` with one sentence (per-example signed-point criteria judged with conversation context, HealthBench-style scoring; criteria live in `Example.expected`).
- [ ] **Step 2:** full suite + `nix develop -c zinc build`; commit `docs: README pointed grader kind` + push.
- [ ] **Step 3:** memory/tracker notes (controller's job): pointed shipped; next HealthBench slices = tag metrics, ingestion CLI, OpenAI grader edge.

---

## Self-Review

**1. Spec coverage:** §1 (kind, criteria location, config knobs, the five error cases) → Task 1 (`criteriaFromExpected` + the branch's example/tv/text checks); §2 (CriterionJudge, transcript w/ system prompt + flattening, criterion rendering w/ signed points + framing, crucible vote live edge, fidelity caveat in haddocks) → Tasks 1 & 3; §3 (formula unclipped, passed Nothing, detail shape, whole-pair error, one row) → Task 1 (pointedGraded/Graded) + Task 2 tests; §4 passRate → Task 2; §5 test list → Tasks 1-2 (pure incl. HealthBench vector + negative score + golden; engine incl. recording judge, sequential-stop-on-error, resume, passRate); §6 out-of-scope absent.

**2. Placeholder scan:** the Task 1 plan-resolution note (live judge moved forward into Task 1 to avoid a lying stub in Main) is explicit instruction, not a TBD; the `"pointed"` branch sketch is marked with its REQUIRED semantics and full logic. Fixed inline during writing: an earlier draft had a placeholder Main judge — eliminated by re-scoping Tasks 1/3.

**3. Type consistency:** `Criterion' {criterion, points, tags}`, `CriterionVerdict {met, explanation}`, `CriterionJudge`, `Graded {value, passed, detail}`, `pointedGraded`, `criteriaFromExpected`, `renderCriterion`, `transcript`, `scoreRun`'s new arity, `noCriterionJudge`, `liveCriterionJudge` — names and shapes match across all three tasks and both test layers.
