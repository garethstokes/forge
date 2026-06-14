# Example Inspector (Slice B) — Design

**Status:** Approved direction + spec-checked against code (2026-06-14). · **Date:** 2026-06-14

**Goal:** A drill-down page for a single example: see its **input**, the
**generated prompt** we actually sent, the **LLM response**, and **all grades**
(including, for pointed graders, the per-criterion verdicts with the judge's
explanation). Reached by clicking a row in the run-detail outputs table.

## Decisions (approved)
- **New drill-down route** (`#/runs/<runId>/ex/<exampleKey>`), back-linked to the
  run — not an inline expand or drawer.
- **Absorbs the per-criterion verdicts** (the standalone score-cell expansion is
  dropped; criteria live here, in the grades section).
- Verdict **explanations show inline** (curious-explorer default).

## Facts (verified against code)
- The raw request/response envelope is **not** stored: `Output.response ::
  Field f (Maybe (Aeson Value))` is written `Nothing` on both the success and
  error branches of `executeRun` (`Execute.hs:170,176`). Only `Output.text`
  (completion), `Output.error`, `Output.latencyMs`, `Output.tokens` are kept.
- Prompt is reconstructable: `Evals.Execute.assembleMessages :: TargetVersion ->
  Example -> Either ExecError [Message]` = `(Message System tv.prompt :) <$>
  decodeInput ex.input` (`Execute.hs:96-98`), both `assembleMessages` and
  `decodeInput` **exported** (`Execute.hs:20-21`). `Crucible.LLM.Message` is a
  **record** `Message { role :: Role, content :: Text }`; `Role =
  System|User|Assistant|Tool`. No role→Text helper is exported — hand-roll one
  (mirror `renderRole` in `Grade.hs:192`: System→"system", User→"user",
  Assistant→"assistant", **Tool→"tool"** — handle all four).
- Pointed `Score.detail = {achieved, possible, criteria:[{criterion, points,
  tags, met, explanation}]}` (written by `pointedGraded`, `Grade.hs:213-224`);
  `axisScoresFromDetail` (`Grade.hs:448`) is a tolerant `parseMaybe`-→`[]`
  template for a `criteriaFromDetail` parser. Pointed detail has **no**
  `rationale` key (so `rationale` is `Nothing` for pointed — the existing
  `scoreDto` reads `detail.rationale` the same way, `Dashboard.hs:264`).
  `Score.error :: Maybe Text`; `Grader.kind :: Text`.
- **`Example.key` is NOT unique** within a dataset version (`Example` indexes =
  `[gin #input, btree #datasetVersion]`, `Schema.hs:205`; keys are ingest input,
  validated only non-empty). → the handler picks the **deterministic first
  match** (lowest example id) and the spec assumes one output per (run,
  example).
- `Evals.Api` pragmas `DeriveAnyClass, DeriveGeneric, DuplicateRecordFields`;
  all DTOs derive `(Eq, Show, Generic, ToJSON, FromJSON)`; derived JSON keys are
  per-record (no cross-DTO clash). Entity-vs-DTO name collisions are renamed by
  convention (`ScoreDto.scoreError`, `OutputRowDto.outputError`).
- Server routing: `dashboardApp` matches `pathInfo` lists; `["api","runs",nTxt]`
  uses `readMaybe` + `badRequest`; `("api":_) -> notFound`; helpers `notFound`/
  `badRequest` (`Dashboard.hs:42-48,99-103`). WAI **percent-decodes** `pathInfo`
  segments, so the matched `key` arrives already decoded. `runDetailHandler`
  (`:224-239`) is the mirror pattern (`get @Run`, `Nothing→notFound`, build in
  `withSession`).
- UI: `Route = RunsR | RunR Int | CompareR Int Int` (`Model.hs:50`); `parseHash`
  splits the hash on `/` (`Model.hs:171`) — so a raw `/` in a key breaks
  routing; `runHash`/`compareHash` builders (`:184`). Fetch wiring is in
  **`Main.hs`** (no Update.hs): `SetRoute`→`Loading`+`fetchRoute` (`Main.hs:53`),
  `fetchRoute` maps route→URL (`:124`), `GotDetail` has a stale-response guard
  (`:77`), `DoRefetch` + `relevantTo :: Route -> MisoString -> Bool`
  (`Model.hs:157`) drive live SSE refetch — all pattern-match the full `Route`
  (adding a constructor forces new arms). `fetchJson` throws on non-2xx **before
  reading the body** (`Fetch.hs:69`), so a 404's `ApiError` JSON is unreachable —
  the UI can only show the HTTP status.

## 1. DTOs (`evals-api/src/Evals/Api.hs`)
```haskell
data PromptMsgDto = PromptMsgDto { role :: Text, content :: Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data CriterionVerdictDto = CriterionVerdictDto
  { criterion :: Text, points :: Double, tags :: [Text], met :: Bool, explanation :: Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data GradeDto = GradeDto
  { graderName :: Text, graderVersion :: Int, graderKind :: Text
  , value :: Maybe Double, passed :: Maybe Bool, rationale :: Maybe Text
  , gradeError :: Maybe Text, criteria :: [CriterionVerdictDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data ExampleDetailDto = ExampleDetailDto
  { runId :: Int, exampleKey :: Text
  , input :: Value, prompt :: [PromptMsgDto]
  , responseText :: Maybe Text, responseError :: Maybe Text
  , grades :: [GradeDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

## 2. Server (`src/Evals/Dashboard.hs`)
- **Route:** add `["api","runs", n, "ex", key]` (before the `("api":_)`
  catch-all) → `exampleDetailHandler pool (RunId n) key`. The `key` is already
  percent-decoded by WAI — no extra decode.
- **Build (`withSession`):** `get @Run`; `Nothing → notFound`. Get the run's
  `TargetVersion`. Select the run's `Output`s, `get @Example` for each, find the
  **first** (lowest example id) whose `key == key`; none → `notFound`. Then:
  - `input = example.input` (unwrap `Aeson`).
  - `prompt = either (const []) (map msg) (assembleMessages tv example)` where
    `msg (Message r c) = PromptMsgDto {role = renderRole r, content = c}` and
    `renderRole` covers all four `Role`s. Decode failure → `[]` (the Input
    section still renders the raw `input`).
  - `responseText = output.text`, `responseError = output.error`.
  - `grades`: each `Score` on the output → `GradeDto` (grader name/version/kind
    via `get @GraderVersion`/`get @Grader`; `value`/`passed`; `rationale` from
    `detail.rationale` when present; `gradeError = score.error`; `criteria =
    criteriaFromDetail score.detail`).
- `criteriaFromDetail :: Maybe (Aeson Value) -> [CriterionVerdictDto]` —
  tolerant `parseMaybe` over the pointed `criteria` array (template:
  `axisScoresFromDetail`); non-pointed / malformed / absent → `[]`.

## 3. UI (`evals-ui/src/Evals/Ui/{Model,View}.hs` + `Main.hs` + `static/style.css`)
- **Route:** add `ExampleR Int Text` to `Route`. Hash `#/runs/<rid>/ex/<enc>`
  where `<enc>` is the **percent-encoded** key (a hand-rolled encoder — no helper
  exists — encoding at least `/`→`%2F`, `#`, `%`, and space so the key survives
  `parseHash`'s `/`-split and the URL fragment); `parseHash` percent-decodes the
  segment back to the raw key. Add an `exampleHash :: Int -> Text -> MisoString`
  builder.
- **Model/fetch (`Main.hs`):** a `RemoteData ExampleDetailDto` model field; a
  `GotExample` action (with the same stale-response guard shape as `GotDetail`);
  `fetchRoute`/`SetRoute` gain an `ExampleR` arm → `fetchJson
  "/api/runs/<rid>/ex/<enc>" GotExample`. **Exhaustiveness:** add the `ExampleR`
  arm to `relevantTo` (map to the same tables `RunR` watches — outputs/scores/
  runs — so SSE refetches the inspector) and to every other full-`Route`
  pattern-match (`DoRefetch`, the `viewModel` route dispatch). A missing example
  (404) surfaces as the generic fetch-failure error state (the server's message
  isn't readable) — that's acceptable.
- **Navigation:** in the run-detail outputs table, the example-key cell links to
  `ExampleR r.runId key` (the output-text cell keeps its in-place truncation
  toggle).
- **View (`exampleView`):** back link + four stacked sections — **Input**
  (render `input`), **Generated prompt** (the `prompt` messages, each
  role-labelled, monospace, visually distinct so the prepended system prompt is
  obvious), **Response** (`responseText` or the red `responseError`), **Grades**
  (per `GradeDto`: name + kind tag + value; for pointed, the `criteria` list with
  ✓/✗ + criterion + tag + points earned + `explanation` inline + the
  `met÷possible = value` total; `gradeError`/`rationale` when present).
- **CSS:** the four sections, role-labelled prompt messages, criterion verdict
  rows (reuse Slice A's tag/✓-✗ styling where present).

## 4. Testing
- **DTO round-trips** (ApiSpec): `PromptMsgDto`, `CriterionVerdictDto`,
  `GradeDto`, `ExampleDetailDto`.
- **Server** (ApiSpec): `GET /api/runs/<rid>/ex/<key>` on a seeded run → assert
  `input`, `prompt` has a `system` turn (the target prompt) + the input turn(s),
  `responseText`, and a pointed `GradeDto.criteria` carries a criterion's
  `met`/`points`/`explanation`; a non-pointed grade has `criteria == []`. An
  unknown key → 404. (If feasible, a key needing URL-encoding through the route.)
- **UI render** has no harness — verified by the wasm build linking + the demo
  (run 1 has a pointed grader with criterion detail).

## 5. Out of scope
- Editing/labelling from the inspector (read-only).
- Raw request/response envelope (not stored — only the completion text).
- Reading the server's 404 message in the UI (fetch can't); diffing examples.
