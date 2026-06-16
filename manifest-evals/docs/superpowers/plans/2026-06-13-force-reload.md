# `metaeval load --force` reload fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** `metaeval load --force` replaces a same-slug+version labelled set.

**Spec:** `docs/superpowers/specs/2026-06-13-force-reload-design.md`

**Repo facts (verified):**
- `src/Evals/Schema.hs` `instance Entity Output` has `cascadeRules = [ cascade (Proxy @Score) (Proxy @"output") Cascade ]`. `CriterionLabel` (`{output :: OutputId, criterion, human, source, createdAt}`) is defined later in the same module. `DatasetVersion→Run` is `Restrict` (`instance Entity DatasetVersion … cascadeRules = [ cascade (Proxy @Example) … Cascade, cascade (Proxy @Run) … Restrict ]`). manifest does recursive cascade deletes (a `Run` delete removes its `Output`s and their `Score`s transitively).
- `src/Evals/MetaEval/Ingest.hs` `metaLoad`'s existing branch:
  ```haskell
              (v : _)
                | not opts.force -> pure (Left (AlreadyExists opts.slug opts.version))
                | otherwise -> do
                    runs <- selectWhere [ #datasetVersion ==. v.id ]
                    if not (null (runs :: [Run]))
                      then pure (Left (HasRuns opts.slug opts.version))
                      else withTransaction $ do
                        delete v
                        flush
                        Right <$> seedGraph d.id opts rows now nSkip
  ```
  `MetaLoadError = BadLine Int Text | NoSuchCriterion Int Text | AlreadyExists Text Int | HasRuns Text Int`; `renderMetaLoadError` has a `HasRuns s v -> …` case. `MetaLoadResult {runId :: RunId, examples :: Int, labels :: Int, skipped :: Int}`. `delete`/`flush`/`withTransaction`/`selectWhere`/`Cond` from `Manifest`.
- `test/MetaEvalSpec.hs` `ingestSpec` (inside the successful-load `Right r -> do` block) currently has, after the load assertions:
  ```haskell
      again <- metaLoad pool (opts True)
      expect "metaLoad refuses an existing version"
        (case again of Left (AlreadyExists "meta" 1) -> True; _ -> False)
      forced <- metaLoad pool (MetaLoadOpts
        { file = "test/fixtures/metaeval.jsonl", name = "Meta", slug = "meta"
        , version = 1, skipBad = True, force = True })
      expect "metaLoad --force is blocked by the synthetic run (HasRuns)"
        (case forced of Left (HasRuns "meta" 1) -> True; _ -> False)
  ```
  `r` (the first load's `Right`) is in scope with `r.runId`/`r.examples`. `opts :: Bool -> MetaLoadOpts`. Local `expect`. `Output`/`CriterionLabel`/`Cond` in scope. Build/test: `nix develop -c zinc build` / `nix develop -c zinc test 2>&1 | tail -8`.

---

### Task 1: cascade rule + force-replace + test (TDD)

**Files:** `src/Evals/Schema.hs`, `src/Evals/MetaEval/Ingest.hs`, `test/MetaEvalSpec.hs`.

- [ ] **Step 1: update the failing test first.** In `test/MetaEvalSpec.hs` `ingestSpec`, REPLACE the `forced <- metaLoad …` + its `expect "metaLoad --force is blocked …"` (the two-line block above) with:
```haskell
      forced <- metaLoad pool (MetaLoadOpts
        { file = "test/fixtures/metaeval.jsonl", name = "Meta", slug = "meta"
        , version = 1, skipBad = True, force = True })
      case forced of
        Left e   -> expect ("metaLoad --force should replace, got: " <> show e) False
        Right r2 -> do
          expect "force: replaced run id differs from the original" (r2.runId /= r.runId)
          expect "force: examples replaced (2, not 4)" (r2.examples == 2)
          lbls2 <- withSession pool (selectWhere ([] :: [Cond CriterionLabel])) :: IO [CriterionLabel]
          expect "force: labels replaced not accumulated (3, not 6)" (length lbls2 == 3)
```
Keep the preceding `again <- metaLoad pool (opts True)` + its `AlreadyExists` assertion as-is. Run `nix develop -c zinc test 2>&1 | tail -8` — FAILS (current force path returns `Left (HasRuns …)`, so the `Right r2` branch isn't taken → `expect … False`; OR a compile error if `RunId`'s `Eq` isn't derived — it is).

- [ ] **Step 2: cascade rule.** In `src/Evals/Schema.hs`, add the `CriterionLabel` cascade to the `Output` instance's `cascadeRules`:
```haskell
  cascadeRules  = [ cascade (Proxy @Score) (Proxy @"output") Cascade
                  , cascade (Proxy @CriterionLabel) (Proxy @"output") Cascade ]
```

- [ ] **Step 3: force path.** In `src/Evals/MetaEval/Ingest.hs`, replace the `(v : _) | otherwise -> do … HasRuns … else withTransaction …` branch with:
```haskell
              (v : _)
                | not opts.force -> pure (Left (AlreadyExists opts.slug opts.version))
                | otherwise -> withTransaction $ do
                    runs <- selectWhere [ #datasetVersion ==. v.id ] :: Db [Run]
                    mapM_ delete runs   -- cascades Run -> Output -> {Score, CriterionLabel}
                    flush               -- runs + subtree gone before deleting the version
                    delete v            -- no runs reference it now (Restrict ok); cascades Examples
                    flush               -- version gone before seedGraph's eager inserts
                    Right <$> seedGraph d.id opts rows now nSkip
```
Then REMOVE the now-unreachable `HasRuns` constructor from `MetaLoadError` and its `renderMetaLoadError` case (grep `HasRuns` to confirm no other use). Run `nix develop -c zinc test 2>&1 | tail -8` — the force test passes (`Right r2`, new run id, 2 examples, 3 labels); all other specs green. If a `HasRuns` removal breaks a reference, fix it; if the cascade delete throws a Restrict at flush, the delete ordering is wrong — investigate (runs must flush before `delete v`).

- [ ] **Step 4: build.** `nix develop -c zinc build 2>&1 | tail -3` — links.

- [ ] **Step 5: README.** In the meta-evaluation docs, update the `--force` note: `metaeval load --force` now replaces an existing slug+version (deletes the prior labelled run graph — examples, outputs, scores, labels — and re-seeds); without `--force` an existing version is refused (`AlreadyExists`). (Remove any prior wording saying `--force` is blocked / that you must bump the version.)

- [ ] **Step 6: commit + push.**
```bash
git add -A
git commit -m "$(printf 'fix(metaeval): --force replaces an existing labelled set\n\nAdd Output->CriterionLabel cascade; metaLoad --force deletes the\nversion runs (cascading outputs/scores/labels) then re-seeds.\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
git push
```

---

## Self-Review
- Spec §1 (Output→CriterionLabel Cascade) → Step 2; §2 (force path delete-runs/flush/delete-v/flush/reseed; remove HasRuns) → Step 3; §3 testing (force → Right, new runId, 2 examples, 3 labels = replaced not accumulated) → Step 1; §4 out-of-scope (no global cascade change, ingest's HasRuns untouched) absent.
- Type consistency: the `Output` cascade rule references `CriterionLabel` (a forward ref in the same module — valid); `metaLoad`'s force branch returns `Right <$> seedGraph …` (matching `IO (Either MetaLoadError MetaLoadResult)`); the test reads `r2.runId :: RunId` (Eq derived) and `r2.examples :: Int`.
