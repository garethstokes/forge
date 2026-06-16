# Research Grounding-Gated Writes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Crucible.Research.Grounded`: a `writeGrounded` combinator that commits a Research page only when its body's claims are supported by a source trace, via `Crucible.Eval.Grounding`.

**Architecture:** An orchestration-level combinator in a row with both `Research meta` and `LLM`. It grounds `page.body` against caller-supplied evidence, then commits with the existing `writePage` only if the supported fraction meets a threshold. A `GroundGate` config carries the threshold, the per-claim vote count, and the caller's NoClaims policy. The `Research` effect and `Eval.Grounding` are unchanged.

**Tech Stack:** GHC 9.12.2, effectful, `Crucible.Eval.Grounding`; zinc build.

**Spec:** `docs/superpowers/specs/2026-06-15-research-grounded-writes-design.md`

## Conventions (every task)
- Build/test: `nix develop . --command timeout -s KILL 300 zinc build|test`. Judge success by exit status or "test suite(s) passed", never a pipeline tail. 137 = GHC flake, retry once; second 137 = BLOCKED. Ignore "Git tree is dirty".
- House style: DuplicateRecordFields + NoFieldSelectors + OverloadedRecordDot. Annotate ambiguous getters and report.
- Tests: custom harness `check "label" expected actual`; comma entries in `runChecks` at END of `test/Spec.hs`. No hspec.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Commit per task; do not push.

## Confirmed facts
- `Crucible.Eval.Grounding` exports `groundingOutcome :: (LLM :> es) => Int -> Text -> Text -> Eff es GroundingOutcome` and `GroundingOutcome (..)` with constructors `GroundingOutcome {supported :: Int, total :: Int, lines' :: [Text]}`, `NoClaims`, `DecomposeFailed Text`.
- `Crucible.Research` exports `Page (..)` (`slug`/`title`/`links`/`body`/`meta`), `Research`, `writePage`, `runResearchState :: [Page meta] -> Eff (Research meta : es) a -> Eff es (a, [Page meta], [Text])`, `runResearchDir`, `Slug (..)`.
- Grounding scripted-reply formats (from existing tests in `test/Spec.hs` ~line 1378): decompose reply is a JSON array of claim strings, e.g. `"[\"the temperature is 26C\",\"the city is Brisbane\"]"`; each per-claim verdict is `"{\"why\":\"...\",\"pass\":true}"` (or `false`); `NoClaims` is decompose reply `"[]"` (no verdicts consumed); `DecomposeFailed` is an unparseable decompose reply plus an unparseable repair reply (two junk replies).
- The interpreter stack for a hermetic test is `runPureEff (runLLMScripted replies (runResearchState seed program))`: `runResearchState` discharges `Research` and passes `LLM` ops through to `runLLMScripted`; the result is the `(value, pages, log)` triple from `runResearchState`.

## File Structure
- Create `src/Crucible/Research/Grounded.hs` — `NoClaimsPolicy`, `GroundGate`, `defaultGroundGate`, `writeGrounded` (Task 1).
- Modify `test/Spec.hs` — hermetic gate tests (Task 1).
- Modify `app/Main.hs` — live demo (Task 2).
- Modify `docs/research.md` — "Grounding-gated writes" section (Task 3).

---

### Task 1: `Crucible.Research.Grounded` + tests

**Files:**
- Create: `src/Crucible/Research/Grounded.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Create `src/Crucible/Research/Grounded.hs`**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeOperators #-}

-- | Grounding-gated writes for 'Crucible.Research'. 'writeGrounded' grounds a
-- page's body against a source trace with 'Crucible.Eval.Grounding' and commits
-- with 'writePage' only if the supported fraction meets the gate's threshold,
-- so a page lands only when its claims are backed by its sources. The gate is
-- opt-in; plain 'writePage' stays unverified. Lives apart from
-- 'Crucible.Research' so that module keeps no dependency on the eval machinery
-- (mirrors 'Crucible.Agents.Gate').
module Crucible.Research.Grounded
  ( NoClaimsPolicy (..)
  , GroundGate (..)
  , defaultGroundGate
  , writeGrounded
  , GroundingOutcome (..)
  ) where

import Data.Text (Text)

import Effectful

import Crucible.Eval.Grounding (GroundingOutcome (..), groundingOutcome)
import Crucible.LLM (LLM)
import Crucible.Research (Page (..), Research, writePage)

-- | What to do when a page body makes no factual claims.
data NoClaimsPolicy = CommitNoClaims | RejectNoClaims
  deriving (Eq, Show)

-- | A write gate over a page's grounding.
data GroundGate = GroundGate
  { threshold  :: Double          -- ^ min fraction of claims supported to commit (1.0 = all)
  , votes      :: Int             -- ^ judge votes per claim (odd; <=1 means one judge call)
  , onNoClaims :: NoClaimsPolicy  -- ^ commit or reject when the body makes no claims
  }

-- | All claims supported, one vote per claim, commit when there are no claims.
defaultGroundGate :: GroundGate
defaultGroundGate = GroundGate 1.0 1 CommitNoClaims

-- | Ground a page's body against the evidence and commit via 'writePage' only if
-- it passes the gate. @Right ()@ means committed; @Left outcome@ means not
-- written (the 'GroundingOutcome' explains why: unsupported claims, a no-claims
-- rejection, or a verifier breakdown).
writeGrounded :: (Research meta :> es, LLM :> es)
              => GroundGate -> Text -> Page meta -> Eff es (Either GroundingOutcome ())
writeGrounded gate evidence page = do
  outcome <- groundingOutcome gate.votes evidence page.body
  case outcome of
    NoClaims -> case gate.onNoClaims of
      CommitNoClaims -> commit
      RejectNoClaims -> pure (Left NoClaims)
    DecomposeFailed _ -> pure (Left outcome)
    GroundingOutcome s t _
      | t == 0                                          -> commit
      | fromIntegral s / fromIntegral t >= gate.threshold -> commit
      | otherwise                                       -> pure (Left outcome)
  where
    commit = writePage page >> pure (Right ())
```
Notes:
- `gate.votes`/`gate.threshold`/`gate.onNoClaims` and `page.body` are OverloadedRecordDot; if a getter section is ambiguous under DuplicateRecordFields, annotate and report.
- `GroundingOutcome (..)` is re-exported (it appears in the module export list) so callers can match the `Left` without importing `Crucible.Eval.Grounding`.
- `DataKinds`/`TypeOperators`/`FlexibleContexts` are for the effect-row constraint; `LambdaCase` for the `\case` (used here as a plain `case`, so `LambdaCase` is optional, remove if it warns unused).

- [ ] **Step 2: Add hermetic tests to `test/Spec.hs`**

Add the import near the other crucible imports:
```haskell
import Crucible.Research.Grounded (NoClaimsPolicy (..), GroundGate (..), defaultGroundGate, writeGrounded)
```
`runPureEff`, `runLLMScripted` are imported; `Page`/`Slug`/`runResearchState`/`GroundingOutcome (..)` are in scope (`GroundingOutcome` via the existing grounding tests' import, or add it). Use `meta = ()` (the gate grounds the body `Text`; no meta codec needed for the pure interpreter). The result of `runResearchState` is `(value, pages, log)`; assert on `(value, pages)`. Add to `runChecks`:

```haskell
  , let page = Page (Slug "p") "P" [] "the temperature is 26C. the city is Brisbane." ()
        (res, pages, _) = runPureEff (runLLMScripted
          [ "[\"the temperature is 26C\",\"the city is Brisbane\"]"
          , "{\"why\":\"ok\",\"pass\":true}"
          , "{\"why\":\"ok\",\"pass\":true}" ]
          (runResearchState [] (writeGrounded defaultGroundGate "Brisbane is 26C." page)))
    in check "writeGrounded: all supported -> committed" (Right (), [page]) (res, pages)
  , let page = Page (Slug "p") "P" [] "the temperature is 26C. it is raining." ()
        (res, pages, _) = runPureEff (runLLMScripted
          [ "[\"the temperature is 26C\",\"it is raining\"]"
          , "{\"why\":\"ok\",\"pass\":true}"
          , "{\"why\":\"evidence says sunny\",\"pass\":false}" ]
          (runResearchState [] (writeGrounded defaultGroundGate "sunny, 26C" page)))
    in check "writeGrounded: an unsupported claim at threshold 1.0 -> rejected, not written"
         (True, ([] :: [Page ()]))
         (case res of Left (GroundingOutcome 1 2 _) -> True; _ -> False, pages)
  , let page = Page (Slug "p") "P" [] "the temperature is 26C. it is raining." ()
        (res, pages, _) = runPureEff (runLLMScripted
          [ "[\"the temperature is 26C\",\"it is raining\"]"
          , "{\"why\":\"ok\",\"pass\":true}"
          , "{\"why\":\"evidence says sunny\",\"pass\":false}" ]
          (runResearchState [] (writeGrounded (defaultGroundGate { threshold = 0.5 }) "sunny, 26C" page)))
    in check "writeGrounded: threshold 0.5 with 1/2 supported -> committed" (Right (), [page]) (res, pages)
  , let page = Page (Slug "p") "P" [] "no factual claims here" ()
        (res, pages, _) = runPureEff (runLLMScripted ["[]"]
          (runResearchState [] (writeGrounded defaultGroundGate "ev" page)))
    in check "writeGrounded: NoClaims under CommitNoClaims -> committed" (Right (), [page]) (res, pages)
  , let page = Page (Slug "p") "P" [] "no factual claims here" ()
        (res, pages, _) = runPureEff (runLLMScripted ["[]"]
          (runResearchState [] (writeGrounded (defaultGroundGate { onNoClaims = RejectNoClaims }) "ev" page)))
    in check "writeGrounded: NoClaims under RejectNoClaims -> rejected, not written"
         (True, ([] :: [Page ()]))
         (case res of Left NoClaims -> True; _ -> False, pages)
  , let page = Page (Slug "p") "P" [] "something" ()
        (res, pages, _) = runPureEff (runLLMScripted ["junk", "junk2"]
          (runResearchState [] (writeGrounded defaultGroundGate "ev" page)))
    in check "writeGrounded: DecomposeFailed -> rejected, not written"
         (True, ([] :: [Page ()]))
         (case res of Left (DecomposeFailed _) -> True; _ -> False, pages)
  , check "writeGrounded: defaultGroundGate fields"
      (1.0, 1 :: Int, CommitNoClaims)
      (defaultGroundGate.threshold, defaultGroundGate.votes, defaultGroundGate.onNoClaims)
```
Notes:
- `Page` derives `Eq`/`Show`, and `()` has both, so the `(Right (), [page])` assertions work.
- If `GroundingOutcome (..)` is not already imported in Spec.hs, add it (from `Crucible.Eval.Grounding` or via the `Crucible.Research.Grounded` re-export). The pattern matches `GroundingOutcome 1 2 _` / `NoClaims` / `DecomposeFailed _` need the constructors in scope.
- `defaultGroundGate.votes` getter may need annotation under DuplicateRecordFields (e.g. `((.votes) defaultGroundGate :: Int)`); annotate and report.
- If `runLLMScripted`/`runResearchState` layering differs, remember `runResearchState` returns the triple; bind `(res, pages, _)`.

- [ ] **Step 3: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the seven new checks pass; full suite green. If a scripted grounding reply format mismatches, copy the exact format from the existing `groundingCheck` tests (~line 1378) and pin. Retry once on 137.

- [ ] **Step 4: Commit**

```bash
git add src/Crucible/Research/Grounded.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(research): writeGrounded grounding-gated writes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Live demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a grounded-write demo**

Read `app/Main.hs`. It imports `qualified Crucible.Research as Research`, `Anthropic.run`, `runEff`, `cfg`, `str`, `TIO`, `T`. Add `import Crucible.Research.Grounded (writeGrounded, defaultGroundGate, GroundingOutcome (..))`. Inside the `Just key -> do` block, after the existing Research demo, add (needs `LLM` via `Anthropic.run`):
```haskell
      -- Grounding-gated writes: a page lands only if its body is supported by
      -- the evidence. One grounded page commits; one ungrounded page is rejected.
      let groundDir = "/tmp/crucible-research-grounded-demo"
          evidence = "Brisbane recorded 26C and sunny skies today."
          grounded   = Research.Page (Research.Slug "weather-ok") "Weather"
                         [] "Brisbane reached 26C and was sunny." ("" :: T.Text)
          ungrounded = Research.Page (Research.Slug "weather-bad") "Weather"
                         [] "Brisbane reached 40C and it snowed." ("" :: T.Text)
      (okRes, badRes) <- runEff (Anthropic.run cfg (Research.runResearchDir str groundDir (do
        a <- writeGrounded defaultGroundGate evidence grounded
        b <- writeGrounded defaultGroundGate evidence ungrounded
        pure (a, b))))
      let render r = case r of
            Right () -> "committed"
            Left o   -> "rejected (" <> T.pack (show o) <> ")"
      TIO.putStrLn ("grounded write (supported): " <> render okRes)
      TIO.putStrLn ("grounded write (unsupported): " <> render badRes)
```
Notes:
- `meta = T.Text` via `str`. The stack `runEff (Anthropic.run cfg (Research.runResearchDir str groundDir prog))`: `runResearchDir` discharges `Research` (needs `IOE`), `Anthropic.run` discharges `LLM`, `runEff` provides `IOE`. If GHC reports the interpreter order differs, adjust and report.
- `writeGrounded` returns `Either GroundingOutcome ()`; `render` prints committed/rejected. The unsupported page should come back `Left` from the live judge (best-effort; if the live model rules it supported, the demo still prints a result, which is acceptable for a smoke demo).

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile. Retry once on 137. (Do not run the binary.)

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "$(cat <<'EOF'
demo(research): grounded write commits supported page, rejects unsupported

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: "Grounding-gated writes" section in `docs/research.md`

**Files:**
- Modify: `docs/research.md`

- [ ] **Step 1: Add the section and update the follow-on list**

Read `docs/research.md`. Insert a `## Grounding-gated writes` section after `## Interpreters` and before `## Planned follow-on work`. Content (real triple-backtick fences):

```markdown
## Grounding-gated writes

A page is only as trustworthy as the write that created it. `writeGrounded`
commits a page only when its body's claims are supported by a source trace.

```haskell
data NoClaimsPolicy = CommitNoClaims | RejectNoClaims
data GroundGate = GroundGate { threshold :: Double, votes :: Int, onNoClaims :: NoClaimsPolicy }
defaultGroundGate :: GroundGate   -- threshold 1.0, votes 1, CommitNoClaims

writeGrounded :: (Research meta :> es, LLM :> es)
              => GroundGate -> Text -> Page meta -> Eff es (Either GroundingOutcome ())
```

`writeGrounded gate evidence page` decomposes the page body into claims, verifies
each against the evidence with the judge, and commits the page with `writePage`
only if the supported fraction meets `threshold`. `Right ()` means committed;
`Left outcome` means it was not written, and the outcome names the unsupported
claims. A body with no factual claims commits or is rejected per `onNoClaims`; a
verifier breakdown always rejects, so an edit is never committed unverified. This
is automated claim-level verified ingest: an agent can write to its knowledge
base and have unsupported claims kept out by default.

To flag rather than gate (always write, but record the grounding result), call
`groundingOutcome` and then `writePage` and `appendLog` yourself; the gate is the
strict default, and the building blocks are public.
```
(The outer ```markdown fence delimits this block in the plan only; write real markdown.)

Then in `## Planned follow-on work`, REMOVE the "grounding-gated writes" item (it now exists). Keep the other items (ops-as-tools, lint). Reword the sentence to read naturally.

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/research.md` (expect no output).
Run: `grep -niE "powerful|seamless|robust|manifest|effortless" docs/research.md` (expect no output).

- [ ] **Step 3: Commit**

```bash
git add docs/research.md
git commit -m "$(cat <<'EOF'
docs(research): Grounding-gated writes section (writeGrounded)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage:** `NoClaimsPolicy`/`GroundGate`/`defaultGroundGate`/`writeGrounded` (T1), all six behavior cases + the defaults check (T1 Step 2), demo (T2), docs + follow-on-list update (T3). Non-goals (flag-mode builtin, auto-evidence, title/links grounding, effect change, per-claim threshold) are "do not build".
- **Type consistency:** `GroundGate {threshold :: Double, votes :: Int, onNoClaims :: NoClaimsPolicy}`, `writeGrounded :: (Research meta :> es, LLM :> es) => GroundGate -> Text -> Page meta -> Eff es (Either GroundingOutcome ())`, re-exported `GroundingOutcome (..)`. Matches spec and the `Crucible.Eval.Grounding`/`Crucible.Research` signatures.
- **Placeholder scan:** no placeholder code. Judgement points flagged: getter annotations under DuplicateRecordFields, the scripted grounding reply formats (copied from the existing tests, with a pin instruction), and the demo interpreter order. No vague steps.
