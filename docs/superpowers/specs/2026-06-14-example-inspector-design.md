# Example Inspector (Slice B) — Design

**Status:** Approved direction (brainstorm w/ visual companion 2026-06-14). · **Date:** 2026-06-14

**Goal:** A drill-down page for a single example: see its **input**, the
**generated prompt** we actually sent, the **LLM response**, and **all grades**
(including, for pointed graders, the per-criterion verdicts with the judge's
explanation). Reached by clicking a row in the run-detail outputs table.

## Decisions (approved)
- **New drill-down route** (`#/runs/<runId>/ex/<exampleKey>`), back-linked to the
  run — not an inline expand or drawer.
- **Absorbs the per-criterion verdicts** (the standalone score-cell expansion
  from earlier drafts is dropped; criteria live here, in the grades section).
- Verdict **explanations show inline** (curious-explorer default).

## Facts (verified)
The raw request/response envelope is **not** stored (`Output.response` is always
`Nothing`); only `Output.text` (the completion) + `Output.error` + tokens. The
prompt is **faithfully reconstructable**: `Evals.Execute.assembleMessages ::
TargetVersion -> Example -> Either ExecError [Message]` = `Message System
tv.prompt : decodeInput example.input`; the server has `TargetVersion` (the
run's target version) + `Example`. `Crucible.LLM.Message {Role, Text}` /
`Role = System|User|Assistant|Tool`. Pointed `Score.detail = {achieved,
possible, criteria:[{criterion, points, tags, met, explanation}]}`;
`Score.error :: Maybe Text`; `Grader.kind :: Text`. `Evals.Api` DTOs are derived
JSON, shared by server + wasm UI. The UI `Route = RunsR | RunR Int | CompareR
Int Int` (hash-routed, parsed in `Evals.Ui.Model`/`Fetch`); fetches via
`fetchJson`. The dashboard server routes on `pathInfo` in `Evals.Dashboard`
(`["api","runs",n]` etc.); `runDetailHandler` shows the per-output/score
mapping pattern to mirror.

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
  , input :: Value                 -- the dataset example's raw input
  , prompt :: [PromptMsgDto]       -- the assembled prompt actually sent (system + input)
  , responseText :: Maybe Text, responseError :: Maybe Text
  , grades :: [GradeDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

## 2. Server (`src/Evals/Dashboard.hs`)
- **Route:** `["api","runs", n, "ex", key]` → `exampleDetailHandler pool (RunId n)
  key`.
- **Build:** find the `Output` for the run whose `Example.key == key` (get the
  run's outputs, join their examples, match the key; 404 if none). Then:
  - `input = example.input` (unwrapped `Value`).
  - `prompt`: `assembleMessages tv example` (reuse `Evals.Execute`) → map each
    `Message r c` to `PromptMsgDto {role = render r, content = c}`; a decode
    error → an empty prompt (the input section still shows the raw input).
  - `responseText = output.text`, `responseError = output.error`.
  - `grades`: each `Score` on the output → `GradeDto` (grader name/version/kind
    via `get @GraderVersion`/`get @Grader`; `value`/`passed`; `rationale` from
    `detail.rationale` when present; `gradeError = score.error`; `criteria` =
    `criteriaFromDetail score.detail` — parse the pointed `criteria` array,
    tolerant → `[]`).
- A `criteriaFromDetail :: Maybe (Aeson Value) -> [CriterionVerdictDto]` helper
  (shared shape with the pointed grader's detail).

## 3. UI (`evals-ui/src/Evals/Ui/{Model,View,Fetch}.hs` + `static/style.css`)
- **Route:** add `ExampleR Int Text` to `Route`; hash `#/runs/<rid>/ex/<key>`
  (URL-encode/decode the key); parse + build in the hash logic. A new
  `RemoteData ExampleDetailDto` model field + `GotExample` action +
  `fetchExample` (fetches `/api/runs/<rid>/ex/<key>`).
- **Navigation:** in the run-detail outputs table, the example-key cell becomes
  a link to `ExampleR` (the output-text cell keeps its in-place truncation
  toggle). 
- **View** (`exampleView`): a back link + four stacked sections:
  1. **Input** — render `input` (the conversation: messages, or a raw value).
  2. **Generated prompt** — the `prompt` messages, each role-labelled
     (system/user/assistant), monospace content; visually distinct from Input so
     the system prompt the target added is obvious.
  3. **Response** — `responseText` (or the red `responseError`).
  4. **Grades** — one block per `GradeDto`: grader name + kind tag + value
     (`✓/✗` for pass/fail kinds, fractional for pointed); for pointed, the
     `criteria` list (✓/✗ + criterion + tag + points earned + `explanation`
     inline) and the `met÷possible = value` total; `gradeError`/`rationale`
     shown when present.
- **CSS:** the four sections, role-labelled prompt messages, the criterion
  verdict rows (reuse Slice A's tag/points/✓-✗ styling where it exists).

## 4. Testing
- **DTO round-trips** (ApiSpec): `PromptMsgDto`, `CriterionVerdictDto`,
  `GradeDto`, `ExampleDetailDto`.
- **Server** (ApiSpec): `GET /api/runs/<rid>/ex/<key>` on a seeded run →
  assert `input`, `prompt` has a `system` turn (the target prompt) + the input
  turn(s), `responseText`, and a pointed `GradeDto.criteria` carries a
  criterion's `met`/`points`/`explanation`; a non-pointed grade has
  `criteria == []`. An unknown key → 404.
- **UI render** has no harness — verified by the wasm build linking +
  eyeballing the demo (the seed's run 1 has a pointed grader with criterion
  detail).

## 5. Out of scope
- Editing/labelling from the inspector (read-only).
- Raw request/response envelope (not stored — only the completion text).
- Diffing two examples / cross-run example view.
