# Cross-Model Judge Panels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `tally` (pure verdict combination) and `votePanel` (run a panel of judges over one rubric/output and tally), in `Crucible.Eval.Judge`.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-13-judge-panels-design.md` (tracker `crucible-ymh`). `tally` is the pure resolution from `vote`'s terminal case, three-way-verdict aware; `votePanel` is `Monad m`-general so it is pure-testable. Each panel member is `judgeOnce` under an interpreter. No changes to `vote`.

**Tech Stack:** Haskell GHC 9.12.2. No -Werror. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). Exit 137 = retry once. Judge by exit status or the pass line, never a pipeline tail.

---

## Background

- Branch `feat/judge-panels` from master. House style: NoFieldSelectors, OverloadedRecordDot. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `Crucible.Eval.Judge` has `Verdict { why, kind }`, `VerdictKind = Pass | Fail | CannotAssess`, `VoteOutcome = Decided { pass, why, dissent, yes, no } | AllErrored Text | AllAbstained Text`, `JudgeError`, `judgeOnce :: (LLM :> es) => [JudgeExample] -> Text -> Text -> Eff es (Either JudgeError Verdict)`. It imports `Data.Maybe (fromMaybe)`.
- Suite passes with 305 checks.
- Keys in `.env` (gitignored). NEVER print/echo/cat them.

---

### Task 1: `tally` + `votePanel` + tests

**Files:** Modify `src/Crucible/Eval/Judge.hs`, `test/Spec.hs`.

- [ ] **Step 1:** In `src/Crucible/Eval/Judge.hs`, add `listToMaybe` to the `Data.Maybe` import (`import Data.Maybe (fromMaybe, listToMaybe)`). Add `tally` and `votePanel` to the export list. Add (after `vote`):

```haskell
-- | Pure mechanical combination of independent verdicts (no LLM). Same
-- resolution as 'vote' with no early stop: Pass tallies as yes, Fail as
-- no, CannotAssess as an abstain, a 'JudgeError' as an excluded sample.
-- With no yes/no votes the outcome is 'AllAbstained' if any sample
-- abstained, else 'AllErrored'; otherwise the majority decides (a tie
-- resolves to fail, matching 'vote'); 'why' is the first winning-side
-- rationale and 'dissent' the first losing-side one.
tally :: [Either JudgeError Verdict] -> VoteOutcome
tally rs =
  let verdicts = [v | Right v <- rs]
      yesWhys  = [v.why | v <- verdicts, v.kind == Pass]
      noWhys   = [v.why | v <- verdicts, v.kind == Fail]
      absWhys  = [v.why | v <- verdicts, v.kind == CannotAssess]
      errs     = [m | Left (JudgeError m) <- rs]
      y = length yesWhys
      f = length noWhys
  in if y == 0 && f == 0
       then case absWhys of
              (w : _) -> AllAbstained w
              []      -> AllErrored (if null errs then "" else last errs)
       else if y > f
              then Decided True  (head yesWhys) (listToMaybe noWhys)  y f
              else Decided False (head noWhys)  (listToMaybe yesWhys) y f

-- | Run a panel of judges over one (rubric, output) and combine with
-- 'tally'. Each member is 'judgeOnce' run under its own interpreter, e.g.
-- @\\r g -> runEff (Anthropic.run cfg (judgeOnce exs r g))@ and an OpenAI
-- twin. A panel of distinct model families gives independent opinions,
-- unlike repeated sampling of one model. 'Monad' m so it is pure-testable
-- with 'Identity'.
votePanel :: Monad m
          => [Text -> Text -> m (Either JudgeError Verdict)]
          -> Text -> Text -> m VoteOutcome
votePanel judges rubric graded =
  tally <$> traverse (\j -> j rubric graded) judges
```

If GHC warns on `head`/incomplete (it should not under the y>f / else guards), leave it; if `-Wx-partial` were on (it is not, no -Werror) it would only warn. If `Eq` on `VerdictKind` is needed for `== Pass` (it derives `Eq`), fine.

- [ ] **Step 2: tests in `test/Spec.hs`.** Add `tally`, `votePanel` to the `Crucible.Eval.Judge` import. Add `import Data.Functor.Identity (Identity (..))` if not present. Add near the vote checks:

```haskell
  -- crucible-ymh: cross-model judge panels
  , check "tally: unanimous pass decides true; tie resolves to fail"
      ((True, 2, 0), (False, 1, 1))
      ( case tally [Right (Verdict "a" Pass), Right (Verdict "b" Pass)] of
          Decided p _ _ y f -> (p, y, f); _ -> (False, -1, -1)
      , case tally [Right (Verdict "a" Pass), Right (Verdict "b" Fail)] of
          Decided p _ _ y f -> (p, y, f); _ -> (False, -1, -1) )
  , check "tally: majority decides and records the first dissent"
      (False, Just "yo")
      (case tally [Right (Verdict "yo" Pass), Right (Verdict "n1" Fail), Right (Verdict "n2" Fail)] of
         Decided p _ d _ _ -> (p, d); _ -> (True, Nothing))
  , check "tally: all abstain -> AllAbstained; all error -> AllErrored; errors excluded"
      (True, True, (True, 1, 0))
      ( case tally [Right (Verdict "x" CannotAssess)] of AllAbstained _ -> True; _ -> False
      , case tally [Left (JudgeError "down")] of AllErrored m -> T.isInfixOf "down" m; _ -> False
      , case tally [Left (JudgeError "e"), Right (Verdict "y" Pass)] of
          Decided p _ _ y f -> (p, y, f); _ -> (False, -1, -1) )
  , check "votePanel: combines member verdicts via tally (pure Identity)"
      (True, 2, 0)
      (case runIdentity (votePanel
              [ \_ _ -> Identity (Right (Verdict "a" Pass))
              , \_ _ -> Identity (Right (Verdict "b" Pass)) ] "r" "out") of
         Decided p _ _ y f -> (p, y, f); _ -> (False, -1, -1))
  , check "votePanel: each member receives the rubric and output"
      ("r|out", "r|out")
      (runIdentity (votePanel
         [ \r g -> Identity (Right (Verdict (r <> "|" <> g) Pass)) ] "r" "out"
       >>= \o -> case o of
                   Decided _ w _ _ _ -> pure (w, "r|out")
                   _                 -> pure ("", "r|out")))
```

If the `votePanel` "each member receives" check's `>>=` shape is awkward, simplify to extract the `why` directly (it equals `r <> "|" <> g`); keep the assertion that the member saw `"r"` and `"out"`. If a result differs, investigate the CODE; never weaken a check.

- [ ] **Step 3: build + suite.** `1 test suite(s) passed`, 310 ok (305 + 5).

- [ ] **Step 4: commit.**

```bash
git add src/Crucible/Eval/Judge.hs test/Spec.hs
git commit -m "$(printf 'feat(judge): cross-model judge panels (pure tally + votePanel)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: demo + live smoke + docs

**Files:** Modify `app/Main.hs`, `docs/evals.md`.

- [ ] **Step 1: demo.** Add `votePanel`, `judgeOnce` to the `Crucible.Eval.Judge` import in `app/Main.hs` (extend; do not duplicate). In the OpenAI-key-gated block (both `cfg` and `ocfg` in scope), add:

```haskell
          panelOut <- votePanel
            [ \r g -> runEff (Anthropic.run cfg (judgeOnce [] r g))
            , \r g -> runEff (OpenAI.run ocfg (judgeOnce [] r g)) ]
            "the output is a friendly greeting" "Hello there, lovely to meet you!"
          TIO.putStrLn ("panel: " <> T.pack (show panelOut))
```

- [ ] **Step 2: build + live smoke.**

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 420 .zinc/build/crucible-anthropic'
```

Expected: a `panel: Decided {pass = True, ...}` line (both families judge the greeting a pass); exit 0. REPORT the exact line.

- [ ] **Step 3: docs.** In `docs/evals.md` voting material, add a "Cross-model judge panels" subsection: `tally` (pure) and `votePanel` (Monad-general), the member-building pattern (`judgeOnce` under each provider's interpreter), why a panel beats n same-model votes (diversity, rule 13), open-loop, and that the majority/dissent semantics match `vote`. House style: no emdashes, no hype, no manifest.

- [ ] **Step 4: commit.**

```bash
git add app/Main.hs docs/evals.md
git commit -m "$(printf 'docs(site)+demo: cross-model judge panel, proven live\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: merge + publish + close

- [ ] **Step 1:** full suite `1 test suite(s) passed`, 310 ok.
- [ ] **Step 2:** merge via `superpowers:finishing-a-development-branch`; suite on master; push; Pages `built`.
- [ ] **Step 3:** `bd close crucible-ymh --reason="Shipped: pure tally :: [Either JudgeError Verdict] -> VoteOutcome (three-way-verdict aware, majority/dissent matching vote) and Monad-general votePanel running a panel of judges (judgeOnce under different interpreters) and combining with tally; 5 tests, live cross-family panel demo, evals.md subsection. Open-loop; per-member counts and Score-wrapper remain non-goals."`

---

## Self-Review

**1. Spec coverage:** `tally` pure resolution matching vote (tie->fail, dissent, abstain/error terminals) -> Task 1. `votePanel` Monad-general over member judge functions -> Task 1. Demo cross-family panel -> Task 2. Docs subsection -> Task 2. Non-goals (per-member counts, Score wrapper, weighted panels, closed-loop) absent. ✅

**2. Placeholder scan:** none; the votePanel "each member receives" test has a stated simplification fallback. ✅

**3. Type consistency:** `tally :: [Either JudgeError Verdict] -> VoteOutcome`; `Decided True (head yesWhys) (listToMaybe noWhys) y f` matches `Decided { pass, why, dissent, yes, no }` field order; `votePanel :: Monad m => [Text -> Text -> m (Either JudgeError Verdict)] -> Text -> Text -> m VoteOutcome` = `tally <$> traverse (\j -> j rubric graded) judges`; tests use `Identity`/`runIdentity`. Counts: 305 + 5 = 310. ✅
