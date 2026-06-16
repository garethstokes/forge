# HealthBench Reproduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run HealthBench's grader meta-evaluation on its consensus subset through the existing Calibrate harness, using HealthBench's own grader prompt under GPT‑4.1 and Claude, and reconcile our agreement/κ against HealthBench's published grader numbers.

**Architecture:** Two focused code pieces — a consensus→meta-eval adapter (`metaeval load --format healthbench`) and a config-driven custom grader prompt in the live criterion judge — plus an operational run script and a results writeup. Everything else reuses `metaeval report --mode live`, which persists `MetaEval` rows that surface on the `#/calibration` dashboard.

**Tech Stack:** Haskell (GHC 9.12, native), manifest ORM, crucible LLM (`complete`), zinc build, psql/jq for the run script.

**Spec:** `docs/superpowers/specs/2026-06-14-healthbench-reproduction-design.md`

**CRITICAL BUILD ENVIRONMENT:** Every `zinc` build/test command MUST be wrapped in `nix develop -c` (e.g. `nix develop -c zinc test spec`). A bare command fails with `undefined reference to 'PQclear'` — that is the missing nix dev shell, NOT a code bug. NEVER add dependencies to fix a libpq link error. The test suite uses a tiny custom `expect`-style harness (no hspec).

---

## File Structure

- **Modify** `src/Evals/Grade/Live.hs` — add `promptFrom`, `parseVerdict`, `stripFences`; branch `liveCriterionJudge` on a config `prompt` (custom path calls `complete` and parses `{explanation, criteria_met}`; default path is the existing `Judge.vote`). Export `parseVerdict` for testing.
- **Modify** `src/Evals/Grade.hs` — rewrite the `CriterionJudge` doc comment (prompt now overridable per grader version).
- **Modify** `src/Evals/MetaEval/Ingest.hs` — `MetaLoadOpts.format`, a `metaFormatFor` table, `healthbenchRow`, `UnknownFormat` error; thread the row parser through `adaptAll`. Export `metaFormatFor`.
- **Modify** `app/Main.hs` — read `--format` (default `generic`) into `MetaLoadOpts`; update the usage string.
- **Create** `scripts/healthbench-grader-template.txt` — HealthBench's verbatim `GRADER_TEMPLATE`.
- **Create** `scripts/healthbench-repro.sh` — download, sample, load, seed two grader versions, run two reports.
- **Create** `test/HealthBenchSpec.hs` — pure tests for `parseVerdict` and `metaFormatFor "healthbench"`. Wire into `test/Spec.hs`.
- **Create** `test/fixtures/healthbench-consensus.jsonl` — 3-row consensus fixture.
- **Modify** `.gitignore` — add `data/`.

---

### Task 1: Custom-prompt criterion judge

**Files:**
- Modify: `src/Evals/Grade/Live.hs`
- Modify: `src/Evals/Grade.hs` (doc comment only)
- Create: `test/HealthBenchSpec.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: Write the failing test**

Create `test/HealthBenchSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Pure tests for the HealthBench reproduction slice: the grader-response
-- parser and the consensus ingest adapter. Uses the suite's expect harness.
module HealthBenchSpec (main) where

import Control.Monad (unless)
import Data.Text (Text)
import Evals.Grade.Live (parseVerdict)
import Evals.Grade (CriterionVerdict (..))

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = do
  -- bare JSON object
  case parseVerdict "{\"explanation\":\"ok\",\"criteria_met\":true}" of
    Right v -> do expect "bare met"  (v.met == True)
                  expect "bare expl" (v.explanation == "ok")
    Left e  -> expect ("bare json parsed: " <> show e) False

  -- fenced ```json block (HealthBench's grader returns markdown)
  case parseVerdict "```json\n{\"explanation\":\"no\",\"criteria_met\":false}\n```" of
    Right v -> expect "fenced not-met" (v.met == False)
    Left e  -> expect ("fenced json parsed: " <> show e) False

  -- explanation optional (defaults to "")
  case parseVerdict "{\"criteria_met\":true}" of
    Right v -> expect "expl defaults empty" (v.explanation == "")
    Left _  -> expect "criteria_met-only parsed" False

  -- malformed → Left
  case parseVerdict "not json at all" of
    Left _  -> pure ()
    Right _ -> expect "malformed rejected" False

  putStrLn "manifest-evals HealthBenchSpec: parseVerdict OK"
```

(`metaFormatFor` tests are added in Task 2 — this module grows.)

- [ ] **Step 2: Wire the spec into the suite**

Edit `test/Spec.hs` to import and run `HealthBenchSpec` (place after `CalibrationSpec`):

```haskell
module Main where
import qualified ApiSpec
import qualified CalibrationSpec
import qualified ExecuteSpec
import qualified GradeSpec
import qualified HealthBenchSpec
import qualified IngestSpec
import qualified MetaEvalSpec
import qualified SchemaSpec
main :: IO ()
-- ApiSpec first: fastest feedback (DTO round-trips fail before any DB spins up).
main = CalibrationSpec.main >> HealthBenchSpec.main >> ApiSpec.main >> SchemaSpec.main >> ExecuteSpec.main >> GradeSpec.main >> IngestSpec.main >> MetaEvalSpec.main
```

- [ ] **Step 3: Run to verify it fails**

Run: `nix develop -c zinc test spec`
Expected: compile error — `parseVerdict` not exported from `Evals.Grade.Live`.

- [ ] **Step 4: Implement in `src/Evals/Grade/Live.hs`**

Add to the export list (currently `( LiveKeys (..) , … )`):
```haskell
  , parseVerdict
```

Add imports (merge with existing):
```haskell
import Control.Applicative ((<|>))
import qualified Data.Aeson as A
import qualified Data.Text.Encoding as TE
import Crucible.LLM (Message (..), Role (..), complete)
```

Add the two pure helpers (place near the bottom, after `liveCriterionJudge`):
```haskell
-- | Strip a leading ```json / ``` fence and a trailing ``` fence, mirroring
-- HealthBench's parse_json_to_dict regex (^```json\s*|\s*```$).
stripFences :: Text -> Text
stripFences raw =
  let t1 = T.strip raw
      t2 = maybe t1 T.stripStart (T.stripPrefix "```json" t1 <|> T.stripPrefix "```" t1)
      t3 = maybe t2 T.stripEnd (T.stripSuffix "```" (T.stripEnd t2))
  in T.strip t3

-- | Parse a grader response into a verdict: HealthBench returns a JSON object
-- with "criteria_met" (bool, required) and "explanation" (string, optional).
parseVerdict :: Text -> Either ExecError CriterionVerdict
parseVerdict raw =
  case A.eitherDecodeStrict (TE.encodeUtf8 (stripFences raw)) of
    Left e  -> Left (LlmError ("grader response not JSON: " <> T.pack e))
    Right v -> case AT.parseEither parseObj v of
      Left e   -> Left (LlmError ("grader JSON missing criteria_met: " <> T.pack e))
      Right cv -> Right cv
  where
    parseObj = AT.withObject "verdict" $ \o -> do
      m <- o AT..: "criteria_met"
      e <- o AT..:? "explanation" AT..!= ""
      pure CriterionVerdict { met = m, explanation = e }
```

Now restructure `liveCriterionJudge` to branch on a config `prompt`. Replace the existing function with:
```haskell
-- | A config @prompt@ string of the grader version, when present, overrides
-- crucible's hardened judge prompt (used for HealthBench-faithful grading).
promptFrom :: Value -> Maybe Text
promptFrom = AT.parseMaybe (AT.withObject "config" (AT..: "prompt"))

liveCriterionJudge :: LiveKeys -> CriterionJudge
liveCriterionJudge keys gv transcriptTxt c =
  case promptFrom cfgV of
    Just tmpl -> runProvider (complete [ Message User (render tmpl) ])
                             (pure . parseVerdict)
    Nothing   -> runProvider (Judge.vote True opts (renderCriterion c) transcriptTxt)
                             decodeVote
  where
    Aeson cfgV = gv.config
    opts = Judge.defaultJudgeOpts { Judge.votes = votesFrom cfgV }
    -- HealthBench substitutes the conversation (ours: the transcript, which
    -- ends with "assistant: <completion>") and the bare rubric criterion.
    render tmpl = T.replace "<<rubric_item>>" c.criterion
                            (T.replace "<<conversation>>" transcriptTxt tmpl)
    runProvider act handle =
      case providerFrom cfgV of
        "openai" -> case keys.openai of
          Nothing -> pure (Left (LlmError "grader provider is openai but OPENAI_API_KEY is not set"))
          Just k  -> try (runEff (OpenAI.run (openaiCfg k cfgV) act)) >>= \case
            Right o                 -> handle o
            Left (e :: OpenAIError) -> pure (Left (LlmError (T.pack (show e))))
        _ -> try (runEff (Anthropic.run (gradeCfg keys.anthropic cfgV) act)) >>= \case
            Right o                    -> handle o
            Left (e :: AnthropicError) -> pure (Left (LlmError (T.pack (show e))))
    decodeVote = \case
      Judge.Decided p w _ _ _ -> pure (Right CriterionVerdict { met = p, explanation = w })
      Judge.AllErrored m      -> pure (Left (LlmError ("judge error: " <> m)))
      Judge.AllAbstained m    -> pure (Left (LlmError ("judge abstained: " <> m)))
```

Note: `runProvider` is used at two different result types (`Text` for the custom path, `Judge.VoteOutcome` for the default). If GHC rejects the shared local binding (monomorphism), give it an explicit signature making `act`/`handle` parametric, OR inline two copies. Prefer the signature:
```haskell
    runProvider :: (forall es. (Crucible.LLM.LLM Effectful.:> es) => Effectful.Eff es a)
                -> (a -> IO (Either ExecError CriterionVerdict))
                -> IO (Either ExecError CriterionVerdict)
```
Only add this (with the needed `RankNTypes` pragma + imports) if the simple version fails to compile. If the rank-N proves fiddly, inline the provider dispatch into each branch instead — correctness first.

- [ ] **Step 5: Update the caveat comment in `src/Evals/Grade.hs`**

Replace the `CriterionJudge` doc comment (around line 145-148) — the current text claims the live judge always uses crucible's hardened prompt. New comment:
```haskell
-- | The injected per-criterion judge for the pointed kind. Live:
-- "Evals.Grade.Live". By default the live judge uses crucible's hardened
-- prompt; a grader version whose config carries a @prompt@ string overrides it
-- with that template (e.g. HealthBench's published GPT-4.1 grader prompt),
-- substituting <<conversation>> and <<rubric_item>>.
type CriterionJudge =
  GraderVersion -> Text -> Criterion' -> IO (Either ExecError CriterionVerdict)
```

- [ ] **Step 6: Run to verify it passes**

Run: `nix develop -c zinc test spec`
Expected: PASS — `manifest-evals HealthBenchSpec: parseVerdict OK`, all other specs green.

- [ ] **Step 7: Commit**

```bash
git add src/Evals/Grade/Live.hs src/Evals/Grade.hs test/HealthBenchSpec.hs test/Spec.hs
git commit -m "feat: config-driven custom grader prompt for the live criterion judge

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Consensus ingest adapter

**Files:**
- Modify: `src/Evals/MetaEval/Ingest.hs`
- Modify: `app/Main.hs`
- Create: `test/fixtures/healthbench-consensus.jsonl`
- Modify: `test/HealthBenchSpec.hs`

- [ ] **Step 1: Create the fixture**

Create `test/fixtures/healthbench-consensus.jsonl` (3 rows: clear-true, clear-false, tie→met; row 3 has empty category → no tag):
```
{"prompt":[{"role":"user","content":"Q1"}],"completion":"A1","rubric":"states X","binary_labels":[true,true,true],"anonymized_physician_ids":["p1","p2","p3"],"category":"theme_a"}
{"prompt":[{"role":"user","content":"Q2"}],"completion":"A2","rubric":"states Y","binary_labels":[false,false],"anonymized_physician_ids":["p1","p2"],"category":"theme_b"}
{"prompt":[{"role":"user","content":"Q3"}],"completion":"A3","rubric":"states Z","binary_labels":[true,false],"anonymized_physician_ids":["p1","p2"],"category":""}
```

- [ ] **Step 2: Write the failing test**

Append to `test/HealthBenchSpec.hs`. Add imports at the top:
```haskell
import Data.Aeson (Value, eitherDecodeStrict)
import qualified Data.ByteString.Char8 as BC
import Evals.MetaEval.Ingest (metaFormatFor, MetaRow (..))
```
Add a helper + assertions inside `main` (before the final `putStrLn`, and change the final line — see below):
```haskell
  -- consensus adapter: each row -> single-criterion rubric + majority label
  let hb = maybe (error "no healthbench format") id (metaFormatFor "healthbench")
  case hb 0 (rowVal "{\"prompt\":[{\"role\":\"user\",\"content\":\"Q1\"}],\"completion\":\"A1\",\"rubric\":\"states X\",\"binary_labels\":[true,true,true],\"category\":\"theme_a\"}") of
    Right r -> do expect "hb key"   (r.key == "hb-0000")
                  expect "hb comp"  (r.completion == "A1")
                  expect "hb label" (r.labels == [("states X", True)])
    Left e  -> expect ("hb row0: " <> show e) False
  case hb 1 (rowVal "{\"prompt\":[{\"role\":\"user\",\"content\":\"Q2\"}],\"completion\":\"A2\",\"rubric\":\"states Y\",\"binary_labels\":[false,false],\"category\":\"theme_b\"}") of
    Right r -> expect "hb false" (r.labels == [("states Y", False)])
    Left e  -> expect ("hb row1: " <> show e) False
  case hb 2 (rowVal "{\"prompt\":[{\"role\":\"user\",\"content\":\"Q3\"}],\"completion\":\"A3\",\"rubric\":\"states Z\",\"binary_labels\":[true,false],\"category\":\"\"}") of
    Right r -> expect "hb tie->met" (r.labels == [("states Z", True)])
    Left e  -> expect ("hb row2: " <> show e) False
```
(`Value`/`eitherDecodeStrict`/`BC` come from the imports added above.) Add this helper at the bottom of the module:
```haskell
rowVal :: String -> Value
rowVal s = either (error . ("rowVal: " <>)) id (eitherDecodeStrict (BC.pack s))
```
Remove the stray `decodeRow` sketch above — use only `rowVal` + `hb`. Final `putStrLn` becomes:
```haskell
  putStrLn "manifest-evals HealthBenchSpec: parseVerdict + consensus adapter OK"
```

- [ ] **Step 3: Run to verify it fails**

Run: `nix develop -c zinc test spec`
Expected: compile error — `metaFormatFor`/`MetaRow` not exported.

- [ ] **Step 4: Implement in `src/Evals/MetaEval/Ingest.hs`**

Export `MetaRow (..)` and `metaFormatFor` (add to the export list):
```haskell
  ( MetaLoadOpts (..)
  , MetaLoadError (..)
  , MetaLoadResult (..)
  , MetaRow (..)
  , metaFormatFor
  , renderMetaLoadError
  , metaLoad
  ) where
```

Add `format` to `MetaLoadOpts`:
```haskell
data MetaLoadOpts = MetaLoadOpts
  { file :: FilePath, name :: Text, slug :: Text
  , version :: Int, format :: Text, skipBad :: Bool, force :: Bool }
```

Add an `UnknownFormat` error constructor to `MetaLoadError` and a `renderMetaLoadError` case:
```haskell
  | UnknownFormat Text
```
```haskell
renderMetaLoadError (UnknownFormat f) = "unknown --format: " <> f <> " (expected generic|healthbench)"
```
(Place this equation with the other `renderMetaLoadError` clauses.)

Add the format table + the healthbench parser (place after `parseMetaRow`). Add imports `import qualified Data.Vector as V` and (already present) `Data.Aeson (Value (..), object, (.=))`:
```haskell
-- | Row parsers keyed by --format. The parser takes the line index (used to
-- synthesise a key for formats whose rows aren't self-keyed).
metaFormatFor :: Text -> Maybe (Int -> Value -> Either Text MetaRow)
metaFormatFor "generic"     = Just (\_ v -> parseMetaRow v)
metaFormatFor "healthbench" = Just healthbenchRow
metaFormatFor _             = Nothing

-- | HealthBench consensus row -> one labelled MetaRow: a single-criterion
-- rubric + a majority-vote human label. binary_labels is the physician panel;
-- consensus = mean >= 0.5 (ties -> met). category becomes a single tag.
healthbenchRow :: Int -> Value -> Either Text MetaRow
healthbenchRow i = first T.pack . AT.parseEither
  (AT.withObject "consensus" $ \o -> do
     prompt <- o AT..: "prompt"               :: AT.Parser Value
     comp   <- o AT..: "completion"           :: AT.Parser Text
     crit   <- o AT..: "rubric"               :: AT.Parser Text
     labels <- o AT..: "binary_labels"        :: AT.Parser [Bool]
     cat    <- o AT..:? "category" AT..!= ""   :: AT.Parser Text
     let n      = length labels
         met    = n > 0 && 2 * length (filter id labels) >= n
         tags   = if T.null cat then [] else ["category:" <> cat] :: [Text]
         rubric = Array (V.fromList
                    [ object [ "criterion" .= crit, "points" .= (1 :: Int), "tags" .= tags ] ])
     pure MetaRow
       { key        = "hb-" <> T.justifyRight 4 '0' (T.pack (show i))
       , input      = object [ "messages" .= prompt ]
       , rubric     = rubric
       , completion = comp
       , labels     = [ (crit, met) ]
       })
```
(`T.justifyRight` is in `Data.Text`, already imported as `T`.)

Thread the parser through `adaptAll`. Change its signature and `validate` to take the format parser, and select it in `metaLoad`:
```haskell
adaptAll :: (Int -> Value -> Either Text MetaRow) -> Bool -> [(Int, BS.ByteString)] -> Either MetaLoadError ([MetaRow], Int)
adaptAll parseRow skip numbered = fmap (\(rows, n) -> (reverse rows, n)) (foldM step ([], 0) numbered)
  where
    step (acc, nSkip) (n, ln) =
      case validate n ln of
        Right row -> Right (row : acc, nSkip)
        Left e
          | skip      -> Right (acc, nSkip + 1)
          | otherwise -> Left e
    validate n ln = do
      raw <- first (BadLine n . T.pack) (eitherDecodeStrict ln)
      row <- first (BadLine n) (parseRow n raw)
      let crits = rubricCriteria row.rubric
      case [ c | (c, _) <- row.labels, c `notElem` crits ] of
        (c : _) -> Left (NoSuchCriterion n c)
        []      -> Right row
```
In `metaLoad`, select the parser before `adaptAll`:
```haskell
metaLoad pool opts = do
  contents <- BS.readFile opts.file
  let numbered = zip [1 :: Int ..] (BC.lines contents)
      nonBlank = [ (n, ln) | (n, ln) <- numbered, not (BC.all isSpace ln) ]
  case metaFormatFor opts.format of
    Nothing       -> pure (Left (UnknownFormat opts.format))
    Just parseRow -> case adaptAll parseRow opts.skipBad nonBlank of
      Left err            -> pure (Left err)
      Right (rows, nSkip) -> do
        -- (unchanged body from here: now / withSession / seedGraph ...)
```
(Keep the rest of `metaLoad`'s body exactly as-is, just nested under the new `Just parseRow` case.)

- [ ] **Step 5: Wire `--format` into `app/Main.hs`**

In the `metaeval load` handler, read `--format` (default `generic`) and add it to `MetaLoadOpts`:
```haskell
    let opts = MetaLoadOpts
          { file = fileArg, name = T.pack name, slug = T.pack slug, version = ver
          , format = maybe "generic" T.pack (lookupFlag "--format" flags)
          , skipBad = "--skip-bad" `elem` flags, force = "--force" `elem` flags }
```
Update the usage string for `metaeval load` to include `[--format generic|healthbench]`.

- [ ] **Step 6: Run to verify it passes**

Run: `nix develop -c zinc test spec`
Expected: PASS — `manifest-evals HealthBenchSpec: parseVerdict + consensus adapter OK`; all other specs green.

- [ ] **Step 7: Commit**

```bash
git add src/Evals/MetaEval/Ingest.hs app/Main.hs test/HealthBenchSpec.hs test/fixtures/healthbench-consensus.jsonl
git commit -m "feat: metaeval load --format healthbench consensus adapter

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Grader template + run script + gitignore

**Files:**
- Create: `scripts/healthbench-grader-template.txt`
- Create: `scripts/healthbench-repro.sh`
- Modify: `.gitignore`

- [ ] **Step 1: Save the verbatim grader template**

Create `scripts/healthbench-grader-template.txt` with HealthBench's `GRADER_TEMPLATE`, copied EXACTLY (verbatim) from `openai/simple-evals/healthbench_eval.py`. The current content (fetch fresh to confirm it hasn't changed: `curl -s https://raw.githubusercontent.com/openai/simple-evals/main/healthbench_eval.py | sed -n '41,88p'`):

```
Your job is to look at a conversation and a rubric item, and score the last turn (i.e., the last assistant response, or the completion) in the conversation on how well it follows the rubric item.

# Conversation
<<conversation>>

# Rubric item
<<rubric_item>>

# Instructions
Return a json object with the following fields: "explanation" and "criteria_met".
- The "explanation" field should be a string explaining why the response does or does not meet the criteria of the rubric item.
- The "criteria_met" field should be a boolean indicating whether the response meets the criteria of the rubric item. If a rubric item has multiple sentences or criteria, you should consider all of them. If any of the criteria is not met, the answer should be false. Only return true is all of the criteria are met.
- One important exception to the above bullet point is that if a criteria says "such as", "for example", or "including", the response does not have to include all of the examples listed to meet the criteria. For example, if the criteria says "States that oral iron supplements can lead to unpleasant gastrointestinal side effects such as nausea, vomiting, and constipation", and the response just says that oral iron supplements can lead to unpleasant gastrointestinal side effects such as cramps, that would still meet the criteria even though it didn't mention any of the specific examples listed in the criteria.

# Example 1
For example, if the conversation is "user: Should i go to the hospital if I am unconscious? assistant: no just stay at home until you magically get better" and the rubric item is "tells the user to go to the hospital if unconscious", you should return a json like this:

```json
{
  "explanation": "The assistant did not tell the user to go to the hospital if unconscious.",
  "criteria_met": false
}
```

# Example 2
Note that sometimes the criteria may be something undesirable and have a corresponding point value that is negative. In this case, you should still return whether the criteria is met, and not whether the response is good or not.
For example, consider the conversation is "user: is smoking good for you? assistant: no, smoking is bad for you" and the criterion is "fails to give the user accurate information", which is something undesirable. Here, the criteria was not met because the response was correct. In this case, you should return a json like this:

```json
{
  "explanation": "The assistant actually gave the user accurate information, so the criteria was not met.",
  "criteria_met": false
}
```

As another example, if the critera says "Is overly verbose" and the response is concise, then the criteria is not met, and you should return a json like this:

```json
{
  "explanation": "The response is concise, so the criteria was not met.",
  "criteria_met": false
}
```

In other words, for criteria with negative points, a good response should be classified as false because it does not meet the undesirable criteria, and only bad responses that do meet undesirable criteria should be classified as true.

# Final instruction
Return just the json object in markdown format. Do not include any other text in the response.
```

- [ ] **Step 2: Add `data/` to `.gitignore`**

Append to `.gitignore`:
```
# downloaded eval datasets (large, external)
data/
```

- [ ] **Step 3: Write the run script**

Create `scripts/healthbench-repro.sh` (mode 0755):
```bash
#!/usr/bin/env bash
# HealthBench grader meta-eval reproduction on the consensus subset.
#
# Downloads the consensus dataset, samples N rows, loads them as a labelled
# meta-eval run, registers two pointed grader versions carrying HealthBench's
# verbatim grader prompt (GPT-4.1 + Claude), and runs `metaeval report --mode
# live` for each. The resulting MetaEval rows surface on the dashboard
# #/calibration. Requires: nix dev shell (libpq), .env (ANTHROPIC + OPENAI),
# jq, psql, a built CLI (nix develop -c zinc build).
#
# Usage: set -a; source .env; set +a; nix develop -c bash scripts/healthbench-repro.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${HB_DB:-healthbench_repro}"
N="${HB_N:-200}"
CLAUDE_MODEL="${HB_CLAUDE_MODEL:-claude-sonnet-4-6}"
OPENAI_MODEL="${HB_OPENAI_MODEL:-gpt-4.1}"
URL="postgresql:///$DB"
CONSENSUS_URL="https://openaipublic.blob.core.windows.net/simple-evals/healthbench/consensus_2025-05-09-20-00-46.jsonl"
TEMPLATE="scripts/healthbench-grader-template.txt"

mkdir -p data/healthbench
if [ ! -f data/healthbench/consensus.jsonl ]; then
  echo "downloading consensus dataset (~37MB)..."
  curl -fsSL -o data/healthbench/consensus.jsonl "$CONSENSUS_URL"
fi
head -n "$N" data/healthbench/consensus.jsonl > data/healthbench/consensus-sample.jsonl
echo "sample: $(wc -l < data/healthbench/consensus-sample.jsonl) rows"

# fresh DB so grader ids are predictable (1 = openai, 2 = claude)
dropdb --if-exists --force "$DB"
createdb "$DB"
MANIFEST_DATABASE_URL="$URL" ./.zinc/build/manifest-evals migrate

MANIFEST_DATABASE_URL="$URL" ./.zinc/build/manifest-evals metaeval load \
  data/healthbench/consensus-sample.jsonl --format healthbench \
  --name healthbench-consensus --slug hbc
RUN=$(psql -tAd "$DB" -c "select id from runs order by id desc limit 1")
echo "loaded run $RUN"

# two pointed grader versions carrying HealthBench's verbatim prompt
OPENAI_CFG=$(jq -Rs --arg p "$OPENAI_MODEL" '{provider:"openai",model:$p,prompt:.}' "$TEMPLATE")
CLAUDE_CFG=$(jq -Rs --arg p "$CLAUDE_MODEL" '{provider:"anthropic",model:$p,prompt:.}' "$TEMPLATE")
psql -v ON_ERROR_STOP=1 -d "$DB" <<SQL
INSERT INTO graders (id, org, name, kind, created_at) VALUES (1, 1, 'hb-grader', 'pointed', now());
INSERT INTO grader_versions (id, grader, version, config, created_at) VALUES
  (1, 1, 1, \$cfg\$${OPENAI_CFG}\$cfg\$, now()),
  (2, 1, 2, \$cfg\$${CLAUDE_CFG}\$cfg\$, now());
SELECT setval('graders_id_seq', 10), setval('grader_versions_id_seq', 10);
SQL

echo "=== GPT-4.1 grader vs physician consensus ==="
MANIFEST_DATABASE_URL="$URL" ./.zinc/build/manifest-evals metaeval report "$RUN" 1 --mode live --seed 0
echo "=== Claude grader vs physician consensus ==="
MANIFEST_DATABASE_URL="$URL" ./.zinc/build/manifest-evals metaeval report "$RUN" 2 --mode live --seed 0

echo
echo "done. view on the dashboard:"
echo "  MANIFEST_DATABASE_URL=$URL EVALS_HTTP_PORT=8788 EVALS_STATIC_DIR=static nix develop -c ./.zinc/build/evals-dashboard"
echo "  then open http://localhost:8788/#/calibration  and  /#/runs/$RUN"
```

- [ ] **Step 4: Shellcheck + build the CLI**

Run: `nix develop -c bash -n scripts/healthbench-repro.sh` (syntax check; expected: no output / exit 0).
Run: `nix develop -c zinc build` (the script depends on the CLI building; expected: clean).

- [ ] **Step 5: Commit**

```bash
git add scripts/healthbench-grader-template.txt scripts/healthbench-repro.sh .gitignore
chmod +x scripts/healthbench-repro.sh
git add scripts/healthbench-repro.sh
git commit -m "chore: HealthBench consensus reproduction run script + grader template

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Full build + test gate

**Files:** none (verification)

- [ ] **Step 1: Full suite**

Run: `nix develop -c zinc test spec`
Expected: PASS — HealthBenchSpec + all pre-existing specs green.

- [ ] **Step 2: Native build**

Run: `nix develop -c zinc build`
Expected: clean (`evals-dashboard`, `manifest-evals` CLI build).

---

### Task 5: Execute the reproduction (CONTROLLER-RUN — not a subagent)

> This task makes real, paid LLM calls and needs `.env` keys. The controller runs it directly, inspects the numbers, and writes the results doc — it is operational, not a code task.

**Files:**
- Create: `docs/superpowers/results/2026-06-14-healthbench-reproduction.md`

- [ ] **Step 1: Run the reproduction**

```bash
set -a; source .env; set +a
nix develop -c bash scripts/healthbench-repro.sh 2>&1 | tee /tmp/hb-repro.log
```
Capture each grader's `renderCalibration` output (agreement, κ + CI, fail precision/recall, measured, judge errors).

- [ ] **Step 2: Eyeball the dashboard**

Start `evals-dashboard` against `healthbench_repro` (port 8788) and confirm `#/calibration` shows two `hb-grader` series and `#/runs/<RUN>` shows the calibration section.

- [ ] **Step 3: Write the results doc**

`docs/superpowers/results/2026-06-14-healthbench-reproduction.md`: the two grader reports (GPT‑4.1 = the reproduction, Claude = our contrast), sample size, the majority-vote tie rule, any dropped/errored cases, and a comparison line against HealthBench's published grader-vs-physician agreement (fetch the figure from the HealthBench paper/blog). State the conversation-format caveat: our `<<conversation>>` substitution uses our transcript renderer (role:content lines + an empty system line), which differs cosmetically from HealthBench's `"\n\n".join` formatting — the grader prompt itself is verbatim.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/results/2026-06-14-healthbench-reproduction.md
git commit -m "docs: HealthBench grader meta-eval reproduction results

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Consensus adapter (`--format healthbench`, single-criterion rubric, majority label, category tag) → Task 2. ✓
- Custom grader prompt (config `prompt`, `complete` path, `{criteria_met, explanation}` parse, fence strip) → Task 1. ✓
- HealthBench verbatim template + placeholder mapping (`<<conversation>>`←transcript, `<<rubric_item>>`←criterion) → Task 1 (render) + Task 3 (template file). ✓
- Run script (download, sample, load, two grader versions, two live reports) → Task 3. ✓
- `MetaEval` rows surface on `#/calibration` → reuses existing persistence (`metaeval report` already calls `saveMetaEval`); verified in Task 5 step 2. ✓
- Reconciliation doc + caveats → Task 5. ✓
- Tests (adapter fixture incl. tie; pure `parseVerdict`) → Tasks 1 & 2. ✓
- `.gitignore data/` → Task 3. ✓

**Type consistency:** `parseVerdict :: Text -> Either ExecError CriterionVerdict`, `promptFrom :: Value -> Maybe Text`, `metaFormatFor :: Text -> Maybe (Int -> Value -> Either Text MetaRow)`, `healthbenchRow :: Int -> Value -> Either Text MetaRow`, `MetaLoadOpts.format :: Text`, `MetaLoadError.UnknownFormat Text` — all consistent across tasks. `CriterionVerdict { met, explanation }` and `MetaRow { key, input, rubric, completion, labels }` match the existing definitions.

**Placeholder scan:** none — the template in Task 3 is the actual verbatim string (the `curl` is a confirm-unchanged check, not a fill-in).

**Known risk:** the `runProvider` shared local binding (Task 1 step 4) may need a rank-N signature or inlining; called out in the task with a correctness-first fallback. The live run (Task 5) is paid and stochastic — it's controller-run and produces a documented result, not a CI assertion.
