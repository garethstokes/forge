# Example Inspector (Slice B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** A drill-down route `#/runs/<id>/ex/<key>` showing an example's input, the reconstructed prompt, the response, and all grades incl. per-criterion verdicts.

**Spec:** `docs/superpowers/specs/2026-06-14-example-inspector-design.md`

**Repo facts (verified):**
- `evals-api/src/Evals/Api.hs`: pragmas `DeriveAnyClass, DeriveGeneric, DuplicateRecordFields`; DTOs derive `(Eq, Show, Generic, ToJSON, FromJSON)`. Existing `RunDetailDto`/`OutputRowDto`/`ScoreDto`/`MetricDto`/`RubricCriterionDto`. Export list groups.
- `src/Evals/Dashboard.hs`: routes on `pathInfo` (`["api","runs",nTxt]` with `readMaybe`+`badRequest`; `("api":_) -> notFound`; `apiWith` wraps handlers). `runDetailHandler` mirrors the get-run/build-in-withSession pattern. `outputRowDto`/`scoreDto` show grader name/version resolution + `selectWhere [#output ==. o.id]`. `rubricCriteriaFromDetail`/`dedupCriteria` are the tolerant-parser templates. Imports: `Manifest (Aeson (..), Cond, Db, get, selectWhere, withSession, Key (..), (==.))`, `Data.Aeson (Value)`, `qualified Data.Aeson.Types as AT`, `Data.List (sortOn, …)`, `Evals.Schema`, `Evals.Ids`, `Evals.Api`. WAI percent-DECODES `pathInfo`, so a route's `key` arrives decoded. `Score {detail :: Maybe (Aeson Value), error :: Maybe Text, value, passed}`; pointed detail `{achieved, possible, criteria:[{criterion, points, tags, met, explanation}]}`.
- `Evals.Execute` EXPORTS `assembleMessages :: TargetVersion -> Example -> Either ExecError [Message]` (= `Message System tv.prompt : decodeInput ex.input`). `Crucible.LLM.Message {role :: Role, content :: Text}`, `Role = System|User|Assistant|Tool`. No exported role→Text — hand-roll (mirror `Grade.hs`'s `renderRole`). `Run.targetVersion :: TargetVersionId`; `Output {example :: ExampleId, text :: Maybe Text, error :: Maybe Text}`; `Example {key :: Text, input :: Aeson Value}`; `TargetVersion {prompt :: Text}`.
- `evals-ui/src/Evals/Ui/Model.hs`: `Route = RunsR | RunR Int | CompareR Int Int` (exports `Route (..)`); `parseHash` splits `#/...` on `/` with `readInt`; `runHash`/`compareHash` builders; `relevantTo route table` (must stay exhaustive over `Route`); `Model {_routeM, _runsM, _detailM, _compareM, _selectedM, _expandedM, _liveM, _refetchQueuedM, _sseConnectedOnceM}`; `emptyModel = Model RunsR NotAsked NotAsked NotAsked [] [] LiveReconnecting False False`; lenses; `Action (..)` (`GotDetail Int (Either …)` is the stale-guard template); `msShow`. Imports `qualified Data.Text as T`.
- `evals-ui/src/Main.hs`: `updateModel` — `SetRoute r` resets per-route Loading + `fetchRoute r`; `GotDetail rid e` stale guard `route <- use routeL; case route of RunR i | i == rid -> …`; `fetchRoute` maps each `Route` → `fetchJson url ctor`. Imports `Evals.Ui.Model` wholesale + `Evals.Ui.Fetch (fetchJson, …)`. `fetchJson :: FromJSON a => MisoString -> (Either MisoString a -> action) -> Effect …`.
- `evals-ui/src/Evals/Ui/View.hs`: `viewModel` `body = case _routeM m of {RunsR -> …; RunR i -> detailView m i; CompareR a b -> …}` (must add an `ExampleR` arm). `detailView m _ = remoteView (_detailM m) $ \d -> div_ [...] [backLink, runHeader (_expandedM m) d.run, outputsTable (_expandedM m) d.run.metrics d.outputs]`. `outputsTable :: [MisoString] -> [MetricDto] -> [OutputRowDto] -> View …`; its `row o` has `td_ [P.class_ "key"] [text (ms o.exampleKey)]` (→ make a link). Helpers `fmtD`, `msShow`, `ms`, `backLink`, `passMark :: Maybe Bool -> View`. Imports `Data.Text (Text)`, `Miso.Html`, `qualified Miso.Html.Property as P`, `Miso.String (MisoString, ms)`, `Evals.Api`, `Evals.Ui.Model`. `pre_`/`h3_`/`a_`/`strong_` from `Miso.Html`.
- wasm artifacts GITIGNORED. Native `nix develop -c zinc build 2>&1 | tail -4`; wasm `scripts/build-ui.sh 2>&1 | tail -6`; tests `nix develop -c zinc test 2>&1 | tail -8`. After the UI change the dashboard binary must be RESTARTED (controller handles it).

---

### Task 1: DTOs (TDD)

**Files:** `evals-api/src/Evals/Api.hs`, `test/ApiSpec.hs`.

- [ ] **Step 1: failing round-trips.** In `test/ApiSpec.hs` `dtoRoundTrips`, add:
```haskell
  rt "PromptMsgDto" PromptMsgDto { role = "system", content = "Answer concisely." }
  rt "CriterionVerdictDto" CriterionVerdictDto
    { criterion = "names the capital", points = 5, tags = ["axis:accuracy"], met = True, explanation = "says Paris" }
  rt "GradeDto" GradeDto
    { graderName = "rubric", graderVersion = 1, graderKind = "pointed", value = Just 0.7
    , passed = Nothing, rationale = Nothing, gradeError = Nothing
    , criteria = [ CriterionVerdictDto { criterion = "c", points = 5, tags = ["axis:accuracy"], met = True, explanation = "" } ] }
  rt "ExampleDetailDto" ExampleDetailDto
    { runId = 1, exampleKey = "capital-fr", input = object ["q" .= ("?" :: Text)]
    , prompt = [ PromptMsgDto { role = "system", content = "Answer." } ]
    , responseText = Just "Paris.", responseError = Nothing
    , grades = [] }
```
Run `nix develop -c zinc test 2>&1 | tail -6` — compile FAIL.

- [ ] **Step 2: DTOs.** In `evals-api/src/Evals/Api.hs`, add to the export list `PromptMsgDto (..), CriterionVerdictDto (..), GradeDto (..), ExampleDetailDto (..)`, and define them:
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
Run `nix develop -c zinc test 2>&1 | tail -6` — round-trips green.

- [ ] **Step 3: commit.** `git add evals-api/src/Evals/Api.hs test/ApiSpec.hs && git commit -m "$(printf 'feat(api): example-inspector DTOs (ExampleDetailDto/GradeDto/…)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"`

---

### Task 2: server endpoint (TDD)

**Files:** `src/Evals/Dashboard.hs`, `test/ApiSpec.hs`.

- [ ] **Step 1: failing server test.** In `test/ApiSpec.hs` `serverSpec` (which already seeds run 1 with a pointed grader "rubric" scoring output `o1` with `detail.criteria`, and a `TargetVersion` with `prompt`), add a GET against the new endpoint for the example behind `o1`. Read the seed to find `o1`'s example key (it's the `Example` `o1` was added against) and the `TargetVersion` prompt text. Assert (decode `ExampleDetailDto`):
  - `input` matches that example's input;
  - `prompt` has ≥2 turns, the first with `role == "system"` and `content` == the target prompt;
  - `responseText == Just <o1.text>`;
  - the `rubric` grade in `grades` has `graderKind == "pointed"` and `criteria` non-empty with the seeded criterion's `met`/`points`/`explanation`; the `exactness` grade has `criteria == []`.
  - a GET for an unknown key returns HTTP 404.
  (Use the existing `getReq`/`testWithApplication` harness in serverSpec; mirror the `/api/runs/<rid>` request style. URL-encoding isn't needed for the demo keys.) Run `nix develop -c zinc test 2>&1 | tail -8` — FAIL (route/handler missing → 404 or decode failure).

- [ ] **Step 2: route + handler.** In `src/Evals/Dashboard.hs`:
  - Add imports: `import Evals.Execute (assembleMessages)` and `import Crucible.LLM (Message (..), Role (..))`.
  - Add the route arm (after `["api","runs",nTxt]`):
    ```haskell
    ["api", "runs", nTxt, "ex", key] ->
      case readMaybe (T.unpack nTxt) :: Maybe Int of
        Nothing -> respond (badRequest "invalid run id")
        Just n  -> apiWith (exampleDetailHandler pool (RunId n) key respond)
    ```
  - Add the handler + helpers:
    ```haskell
    exampleDetailHandler :: Pool -> RunId -> T.Text -> (Response -> IO a) -> IO a
    exampleDetailHandler pool rid key respond = do
      mDto <- withSession pool $ do
        mRun <- get @Run (Key rid)
        case mRun of
          Nothing  -> pure Nothing
          Just run -> do
            mtv  <- get @TargetVersion (Key run.targetVersion)
            outs <- selectWhere [ #run ==. rid ] :: Db [Output]
            paired <- mapM (\o -> do { me <- get @Example (Key o.example); pure (o, me) }) outs
            case sortOn (\(o, _) -> outIdInt o.id) [ (o, e) | (o, Just e) <- paired, e.key == key ] of
              []            -> pure Nothing
              ((o, e) : _)  -> do
                scores <- selectWhere [ #output ==. o.id ] :: Db [Score]
                grades <- mapM gradeDto scores
                let Aeson inputV = e.input
                    prompt = case mtv of
                      Just tv -> either (const []) (map msgDto) (assembleMessages tv e)
                      Nothing -> []
                pure (Just ExampleDetailDto
                  { runId = let RunId n = rid in n, exampleKey = key
                  , input = inputV, prompt = prompt
                  , responseText = o.text, responseError = o.error
                  , grades = sortOn (\g -> g.graderName) grades })
      case mDto of
        Nothing  -> respond notFound
        Just dto -> respond (json status200 dto)
      where outIdInt (OutputId n) = n

    msgDto :: Message -> PromptMsgDto
    msgDto (Message r c) = PromptMsgDto { role = renderRole r, content = c }
      where renderRole = \case { System -> "system"; User -> "user"; Assistant -> "assistant"; Tool -> "tool" }

    gradeDto :: Score -> Db GradeDto
    gradeDto s = do
      mgv <- get @GraderVersion (Key s.graderVersion)
      mg  <- maybe (pure Nothing) (\gv -> get @Grader (Key gv.grader)) mgv
      let gName = maybe "?" (.name) mg; gVersion = maybe 0 (.version) mgv; gKind = maybe "?" (.kind) mg
          rationale = s.detail >>= \(Aeson v) -> AT.parseMaybe (AT.withObject "d" (AT..: "rationale")) v
      pure GradeDto
        { graderName = gName, graderVersion = gVersion, graderKind = gKind
        , value = s.value, passed = s.passed, rationale = rationale
        , gradeError = s.error, criteria = verdictsFromDetail s.detail }

    verdictsFromDetail :: Maybe (Aeson Value) -> [CriterionVerdictDto]
    verdictsFromDetail Nothing = []
    verdictsFromDetail (Just (Aeson v)) = maybe [] id (AT.parseMaybe p v)
      where p = AT.withObject "detail" $ \o -> do
                  arr <- o AT..: "criteria"
                  mapM (AT.withObject "criterion" $ \c ->
                          CriterionVerdictDto <$> c AT..: "criterion" <*> c AT..: "points"
                                              <*> c AT..: "tags" <*> c AT..: "met" <*> c AT..: "explanation")
                       (arr :: [Value])
    ```
    (`renderRole`/`gradeDto`'s `\case` needs `LambdaCase` — it's likely on; if not, add `{-# LANGUAGE LambdaCase #-}`. `OutputId` is from `Evals.Ids`.)
  Run `nix develop -c zinc test 2>&1 | tail -8` — server test green. `nix develop -c zinc build 2>&1 | tail -4` — links.

- [ ] **Step 3: commit.** `git add src/Evals/Dashboard.hs test/ApiSpec.hs && git commit -m "$(printf 'feat(dashboard): /api/runs/:id/ex/:key example-detail endpoint\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"`

---

### Task 3: UI route + inspector view

**Files:** `evals-ui/src/Evals/Ui/Model.hs`, `evals-ui/src/Main.hs`, `evals-ui/src/Evals/Ui/View.hs`, `static/style.css`. (No unit harness — native + wasm build.)

- [ ] **Step 1: Model — route, hash, encode, model field, action.** In `Model.hs`:
  - `Route` gains `| ExampleR Int Text`.
  - Export `exampleL`, `exampleHash`, `encodeSegment` (add to the module export list).
  - `parseHash`: add an arm before the `_ -> RunsR` fallthrough:
    ```haskell
    ["", "runs", n, "ex", k] | Just i <- readInt n -> ExampleR i (decodeSegment k)
    ```
  - Builders + percent helpers (no std encoder in this wasm build):
    ```haskell
    exampleHash :: Int -> T.Text -> MisoString
    exampleHash i k = "#/runs/" <> msShow i <> "/ex/" <> ms (encodeSegment k)

    encodeSegment :: T.Text -> T.Text
    encodeSegment = T.concatMap enc
      where enc '%' = "%25"; enc '/' = "%2F"; enc '#' = "%23"
            enc ' ' = "%20"; enc '?' = "%3F"; enc '&' = "%26"; enc c = T.singleton c

    decodeSegment :: T.Text -> T.Text
    decodeSegment = T.replace "%25" "%" . T.replace "%2F" "/" . T.replace "%23" "#"
                  . T.replace "%20" " " . T.replace "%3F" "?" . T.replace "%26" "&"
    ```
  - `relevantTo`: add `ExampleR _ _ -> table `elem` detailTables`.
  - `Model`: add `_exampleM :: RemoteData ExampleDetailDto` (after `_compareM`); `emptyModel = Model RunsR NotAsked NotAsked NotAsked NotAsked [] [] LiveReconnecting False False`; add `exampleL = lens _exampleM $ \r x -> r { _exampleM = x }`.
  - `Action`: add `| GotExample Int T.Text (Either MisoString ExampleDetailDto)`.

- [ ] **Step 2: Main — SetRoute/fetch/GotExample.** In `Main.hs` `updateModel`:
  - `SetRoute`: add `ExampleR _ _ -> do { exampleL .= Loading; expandedL .= [] }` to the `case r of` block.
  - Add the handler (after `GotCompare`):
    ```haskell
    GotExample rid k e -> do
      route <- use routeL
      case route of
        ExampleR i kk | i == rid, kk == k -> exampleL %= \old -> keepStale old (fromEither e)
        _ -> pure ()
    ```
  - `fetchRoute`: add `ExampleR i k -> fetchJson ("/api/runs/" <> msShow i <> "/ex/" <> ms (encodeSegment k)) (GotExample i k)`.

- [ ] **Step 3: View — dispatch, link, inspector.** In `View.hs`:
  - `viewModel` `body`: add `ExampleR i k -> exampleView m i k`.
  - `outputsTable`: add a leading `Int` run-id param — `outputsTable :: Int -> [MisoString] -> [MetricDto] -> [OutputRowDto] -> View Model Action`; `outputsTable rid expandedKeys metrics outputs = …`; in `row o`, change the key cell to a link: `td_ [ P.class_ "key" ] [ a_ [ P.href_ (exampleHash rid o.exampleKey) ] [ text (ms o.exampleKey) ] ]`. Update the `detailView` caller: `outputsTable d.run.runId (_expandedM m) d.run.metrics d.outputs`.
  - Add the inspector:
    ```haskell
    exampleView :: Model -> Int -> Text -> View Model Action
    exampleView m _ _ =
      remoteView (_exampleM m) $ \d ->
        div_ [ P.class_ "example" ]
          [ a_ [ P.href_ (runHash d.runId), P.class_ "back" ] [ text "← run" ]
          , h2_ [] [ text ("example " <> ms d.exampleKey) ]
          , exSection "Input" [ pre_ [ P.class_ "io" ] [ text (renderJson d.input) ] ]
          , exSection "Generated prompt" (map promptMsg d.prompt)
          , exSection "Response" [ responseBlock d.responseText d.responseError ]
          , exSection "Grades" (map gradeBlock d.grades)
          ]
      where
        exSection title kids = div_ [ P.class_ "ex-section" ] (h3_ [] [ text title ] : kids)

    renderJson :: Value -> MisoString
    renderJson = ms . LT.toStrict . encodeToLazyText

    promptMsg :: PromptMsgDto -> View Model Action
    promptMsg p =
      div_ [ P.class_ ("msg " <> ms p.role) ]
        [ span_ [ P.class_ "role" ] [ text (ms p.role) ]
        , pre_ [ P.class_ "content" ] [ text (ms p.content) ] ]

    responseBlock :: Maybe Text -> Maybe Text -> View Model Action
    responseBlock _ (Just e)        = div_ [ P.class_ "cell-error" ] [ text (ms e) ]
    responseBlock (Just t) Nothing  = pre_ [ P.class_ "io" ] [ text (ms t) ]
    responseBlock Nothing Nothing   = div_ [ P.class_ "muted" ] [ text "–" ]

    gradeBlock :: GradeDto -> View Model Action
    gradeBlock g =
      div_ [ P.class_ "grade" ]
        ( div_ [ P.class_ "grade-head" ]
            [ strong_ [] [ text (ms g.graderName) ], text (" v" <> msShow g.graderVersion)
            , span_ [ P.class_ "kind" ] [ text (ms g.graderKind) ]
            , span_ [ P.class_ "gval" ] [ text (maybe "–" fmtD g.value), passMark g.passed ] ]
          : [ verdictRow c | c <- g.criteria ]
          ++ [ div_ [ P.class_ "cell-error" ] [ text ("⚠ " <> ms e) ] | Just e <- [g.gradeError] ]
          ++ [ div_ [ P.class_ "muted" ] [ text (ms r) ] | Just r <- [g.rationale] ] )
      where
        verdictRow c =
          div_ [ P.class_ "cr" ]
            [ span_ [ P.class_ (if c.met then "m ok" else "m fail") ] [ text (if c.met then "✓" else "✗") ]
            , span_ [ P.class_ "ctxt" ] [ text (ms c.criterion), span_ [ P.class_ "why" ] [ text (ms c.explanation) ] ]
            , span_ [ P.class_ "crit-tags" ] [ span_ [ P.class_ "tag" ] [ text (ms t) ] | t <- c.tags ]
            , span_ [ P.class_ "earn" ] [ text (if c.met then "+" <> fmtD c.points else "0 / " <> fmtD c.points) ] ]
    ```
  - Imports to add to `View.hs`: `import Data.Aeson (Value)`, `import Data.Aeson.Text (encodeToLazyText)`, `import qualified Data.Text.Lazy as LT`. (`exampleHash`/`runHash` come from `Evals.Ui.Model`.)

- [ ] **Step 4: CSS.** In `static/style.css`, add:
```css
.example .ex-section { margin:14px 0; }
.example h3 { font-size:11px; text-transform:uppercase; letter-spacing:.05em; color:var(--muted); margin:0 0 6px; }
.example .io { background:#f7f8fa; border:1px solid var(--line); border-radius:8px; padding:10px 12px; white-space:pre-wrap; font:12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; overflow-x:auto; }
.example .msg { border:1px solid var(--line); border-radius:8px; margin-bottom:6px; overflow:hidden; }
.example .msg .role { display:block; background:#eef0f4; color:var(--muted); font-size:10px; text-transform:uppercase; letter-spacing:.05em; padding:3px 10px; }
.example .msg.system .role { background:#ede9fe; color:#5b21b6; }
.example .msg .content { margin:0; padding:9px 12px; white-space:pre-wrap; font:12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
.example .grade { border:1px solid var(--line); border-radius:9px; padding:10px 12px; margin-bottom:8px; }
.example .grade-head { display:flex; align-items:baseline; gap:8px; }
.example .grade-head .gval { margin-left:auto; font-variant-numeric:tabular-nums; }
.example .cr { display:grid; grid-template-columns:18px 1fr auto 70px; gap:9px; align-items:baseline; padding:5px 0; border-top:1px dotted var(--muted-bg); }
.example .cr:nth-of-type(2) { border-top:none; }
.example .cr .m.ok { color:#166534; } .example .cr .m.fail { color:#991b1b; }
.example .cr .why { display:block; color:#8b93a1; font-size:11.5px; margin-top:1px; }
.example .cr .tag { font-size:11px; border-radius:999px; padding:0 8px; margin-left:4px; background:#e3f5f4; color:#0f6e69; white-space:nowrap; }
.example .cr .earn { text-align:right; font-variant-numeric:tabular-nums; font-size:12px; }
.example .muted { color:var(--muted); font-size:12px; }
```

- [ ] **Step 5: build native + wasm.** `nix develop -c zinc build 2>&1 | tail -4` (native — confirm `Route` exhaustiveness across `viewModel`/`relevantTo`/`SetRoute`/`fetchRoute` is satisfied; `containers`/`text-lazy` aren't new deps — `Data.Text.Lazy`/`Data.Aeson.Text` come from `text`/`aeson` already in the wasm lock). `scripts/build-ui.sh 2>&1 | tail -6` (wasm; final line `done. serve with: …`). Fix any compile error (a missing `Route` arm, an import) and rebuild.

- [ ] **Step 6: commit + push (NOT wasm artifacts).**
```bash
git add evals-ui/src/Evals/Ui/Model.hs evals-ui/src/Main.hs evals-ui/src/Evals/Ui/View.hs static/style.css
git commit -m "$(printf 'feat(ui): example inspector route + view (input/prompt/response/grades)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
git push
```
`git status` must show `static/*.wasm`/jsffi/miso.js ignored (not staged).

---

## Self-Review
- Spec §1 DTOs → Task 1; §2 endpoint (route, first-match by example id, prompt via `assembleMessages`+`renderRole`, grades incl. verdicts, 404) → Task 2; §3 UI (ExampleR route + percent-encode/decode, model/fetch/stale-guard, `relevantTo`, the key-cell link, the four-section `exampleView`) → Task 3; §4 testing (DTO round-trips + server endpoint + UI build) → Tasks 1–3; §5 out-of-scope (read-only, no raw envelope, 404 body unread) honored.
- Type consistency: the four DTOs (Task 1) are produced by `exampleDetailHandler`/`gradeDto`/`msgDto`/`verdictsFromDetail` (Task 2) and consumed by `exampleView`/`promptMsg`/`gradeBlock`/`verdictRow` (Task 3) with matching field names (`role`/`content`; `criterion`/`points`/`tags`/`met`/`explanation`; `graderName`/`graderKind`/`value`/`passed`/`rationale`/`gradeError`/`criteria`; `runId`/`exampleKey`/`input`/`prompt`/`responseText`/`responseError`/`grades`). `ExampleR Int Text` + `exampleHash`/`encodeSegment`/`decodeSegment` consistent across Model/Main/View; `relevantTo`/`SetRoute`/`fetchRoute`/`viewModel` all gain the `ExampleR` arm (exhaustiveness).
