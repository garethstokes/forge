# HealthBench reproduction (grader meta-eval on the consensus subset) — design

**Date:** 2026-06-14
**Status:** approved (pending spec review)

## Goal

Reproduce HealthBench's **grader meta-evaluation** on its consensus subset: feed real
physician-consensus labels into the existing meta-eval/Calibrate harness, judge each
rubric criterion with HealthBench's *own* grader prompt under two backends (GPT‑4.1 and
Claude), and compare our agreement / Cohen's κ / fail-precision-recall against
HealthBench's published grader-vs-physician numbers. Success = **methodology fidelity on a
~200-example sample**: the pipeline runs end-to-end on real data and our GPT‑4.1 number
lands in HealthBench's published band.

This closes the loop: the persisted `MetaEval` rows surface on the `#/calibration`
dashboard built on 2026-06-14 — real HealthBench calibration data in the UI.

## Why this shape

The meta-eval harness already does the hard part — `CriterionLabel` holds gold human
verdicts, `metaeval load` seeds a labelled run graph, `metaeval report --mode live`
re-judges per criterion and computes the calibration report (`reportFromVerdicts`). The
consensus subset is exactly grader-validation data. So the work is: (a) a consensus→meta-eval
adapter, (b) a config-driven custom grader prompt so we can use HealthBench's exact
template (true reproduction, not a directional comparison), (c) a run script, (d) a
reconciliation writeup.

## Data: the grader meta-eval dataset

Source = `INPUT_PATH` in `openai/simple-evals/healthbench_meta_eval.py`:
`https://openaipublic.blob.core.windows.net/simple-evals/healthbench/2025-05-07-06-14-12_oss_meta_eval.jsonl`

(NB: NOT the `consensus_*.jsonl` file — that is the main eval's *consensus subset*
of prompts+rubrics with no physician labels. The grader meta-eval dataset with
`binary_labels` is the `_oss_meta_eval.jsonl` above.)

Each line (the meta-eval record, per `healthbench_meta_eval.py`):

| field | type | use |
|---|---|---|
| `prompt` | list[{role,content}] | the conversation |
| `completion` | str | the model response being judged |
| `rubric` | str | a **single** criterion to assess |
| `binary_labels` | list[bool] | physician judgments (ground truth) |
| `anonymized_physician_ids` | list[str] | (ignored) |
| `category` | str | criterion category tag |

Consensus label = **majority vote**: `met = (sum binary_labels / length) ≥ 0.5` (ties → met).

## Component 1 — Consensus adapter (`Evals.MetaEval.Ingest`)

Add a format selector to `metaeval load`, mirroring the regular `ingest` CLI's
`--format generic|healthbench`:

- `MetaLoadOpts` gains `format :: Text` (default `"generic"`).
- A `healthbench` parser maps one consensus row → the existing `MetaRow`:
  - `key` = a stable per-row key, `hb-<zero-padded-index>` (rows aren't otherwise uniquely
    keyed; index within the sampled file is stable and unique).
  - `input` = `{"messages": <prompt>}`.
  - `completion` = `<completion>`.
  - `rubric` = `[{"criterion": <rubric>, "points": 1, "tags": ["category:<category>"]}]`
    (points are irrelevant to met/not but the pointed grader needs a rubric; a single
    positive-point criterion satisfies `criteriaFromExpected`).
  - `labels` = `[{"criterion": <rubric>, "met": majority(binary_labels)}]`.
- CLI: `metaeval load <file> --format healthbench --name … --slug … [--version --skip-bad --force]`.
  `app/Main.hs` reads `--format` (default `generic`) and threads it into `MetaLoadOpts`.

The two formats live behind a small `metaFormatFor :: Text -> Maybe (Value -> Either Text MetaRow)`
table, so adding formats stays additive and the parser is unit-testable in isolation.

## Component 2 — Custom grader prompt (`Evals.Grade.Live`)

The criterion judge currently always goes through crucible's `Judge.vote` (a fixed
hardened prompt). Add a config-driven override so a grader version can carry its own
prompt — this is what makes the reproduction faithful.

- `promptFrom :: Value -> Maybe Text` reads the config's optional `prompt` key.
- `liveCriterionJudge` branches:
  - **`prompt` present** → render the template by substituting `<<conversation>>` with the
    transcript (already built by `Evals.Grade.transcript`; it ends with
    `assistant: <completion>`) and `<<rubric_item>>` with the criterion text, then run
    `act = complete [Message User rendered]` through the SAME provider wrappers
    (`Anthropic.run (gradeCfg …)` / `OpenAI.run (openaiCfg …)`), and parse the response.
  - **`prompt` absent** → the existing `Judge.vote` path, unchanged.
- Response parsing — `parseVerdict :: Text -> Either ExecError CriterionVerdict`: strip a
  leading/trailing markdown code fence (```` ```json `` … `` ``` ````), `json.loads`-equivalent
  decode of `{"explanation": str, "criteria_met": bool}` → `CriterionVerdict { met, explanation }`.
  A response missing `criteria_met` or not a bool → `Left (LlmError …)`. This mirrors
  HealthBench's `parse_json_to_dict` + `grade_rubric_item` validation.
- `complete` is `Crucible.LLM.complete :: (LLM :> es) => [Message] -> Eff es Text` — already
  in scope via the provider modules; no crucible change.
- Update the `CriterionJudge` doc comment (`Grade.hs:147`): the prompt is now overridable
  per grader version; the hardened-prompt caveat applies only when no `prompt` is set.

### The HealthBench template

Stored as the grader versions' config `prompt`, **fetched verbatim** from
`simple-evals/healthbench_eval.py` `GRADER_TEMPLATE` during implementation (the live
string is the source of truth — the implementer copies it exactly). Known shape: it opens
`"Your job is to look at a conversation and a rubric item, and score the last turn…"`, uses
the placeholders `<<conversation>>` and `<<rubric_item>>`, and instructs the model to
"Return a json object with the following fields: 'explanation' and 'criteria_met'". Our two
placeholders (`<<conversation>>`, `<<rubric_item>>`) are substituted as above.

## Component 3 — Acquisition + run (`scripts/healthbench-repro.sh`)

`nix develop -c bash scripts/healthbench-repro.sh` (needs `.env`: `ANTHROPIC` required,
`OPENAI` required for the gpt‑4.1 grader):

1. Download the consensus JSONL to `data/healthbench/consensus.jsonl` (gitignored;
   `data/` added to `.gitignore`). Skip if present.
2. Deterministic ~200-row sample → `data/healthbench/consensus-200.jsonl`
   (`head -n 200`; deterministic and reproducible — no shuffle).
3. Create/refresh the demo DB graph: `manifest-evals metaeval load
   data/healthbench/consensus-200.jsonl --format healthbench --name healthbench-consensus
   --slug hbc` (capture the printed run id).
4. Insert two pointed grader versions via psql: grader `hb-grader`, versions
   `{"provider":"openai","model":"gpt-4.1","prompt":"<GRADER_TEMPLATE>"}` and
   `{"provider":"anthropic","model":"claude-sonnet-4-6","prompt":"<GRADER_TEMPLATE>"}`
   (the Claude model is a script variable, easy to change). The template
   is read from a single source file (`scripts/healthbench-grader-template.txt`) so the
   SQL and any test share one copy.
5. `set -a; source .env; set +a` then `manifest-evals metaeval report <run> <gvOpenAI>
   --mode live --seed 0` and `… <gvClaude> --mode live --seed 0`. Each prints
   `renderCalibration` and persists a `MetaEval` row.
6. Echo where to view: `#/calibration` and `#/runs/<run>` on a running dashboard against
   the same DB.

The script is operational glue, not Haskell. The grader-version SQL + template live with it.

## Component 4 — Reconciliation

A results doc `docs/superpowers/results/2026-06-14-healthbench-reproduction.md` (created at
run time, committed): the agreement / κ (with CI) / fail-precision / fail-recall for each
backend (GPT‑4.1 is the reproduction; Claude is our own grader for contrast), a note on the
published HealthBench grader-agreement figure for comparison, the
sample size, and a screenshot or description of the `#/calibration` view. Honest caveats:
sample (~200, wide-ish κ CI), majority-vote tie rule, any examples dropped (judge errors).

## Testing

- **`test/MetaEvalSpec.hs`** (or a new `test/HealthBenchSpec.hs` wired into `test/Spec.hs`):
  a 3-row consensus fixture `test/fixtures/healthbench-consensus.jsonl` exercising the
  adapter — one clear-majority-true, one clear-false, one **tie** (even labels, → met) —
  asserting each `MetaRow` has a single-criterion rubric, the `category:<…>` tag, the
  `{"messages":…}` input, and the right `met` label.
- **Custom-prompt verdict parsing** — a pure unit test of `parseVerdict` over: a bare JSON
  object, a fenced ```` ```json `` … `` ``` ```` block, and a malformed response (→ Left).
  This is the one piece of the live path that's deterministically testable.
- All via `nix develop -c zinc test spec` (libpq link needs the dev shell). The live run is
  verified operationally by the script, not in CI.

## Out of scope

- The full 3.7k consensus run, the main/hard subsets, and hitting a model's published
  HealthBench *score* (that's the target-model eval, not grader meta-eval).
- Per-category macro-F1 the exact way HealthBench aggregates it — we report agreement/κ
  (the harness's metrics) plus a category breakdown if cheap; not a reimplementation of
  their F1 pipeline.
- A general templating language — substitution is literal replacement of the two known
  placeholders, nothing more.

## File map

- Modify: `src/Evals/MetaEval/Ingest.hs` (format selector + healthbench parser),
  `app/Main.hs` (`--format` flag), `src/Evals/Grade/Live.hs` (custom-prompt judge +
  `parseVerdict`), `src/Evals/Grade.hs` (caveat comment; maybe export `transcript`/helpers
  if Live needs them — it already imports `renderCriterion`).
- Create: `scripts/healthbench-repro.sh`, `scripts/healthbench-grader-template.txt`,
  `test/fixtures/healthbench-consensus.jsonl`, the results doc (at run time),
  `.gitignore` entry for `data/`.
- Test: `test/MetaEvalSpec.hs` (or new `HealthBenchSpec.hs`) + `test/Spec.hs` wiring.
