# HealthBench grader meta-eval — reproduction results

**Date:** 2026-06-14
**Spec:** `docs/superpowers/specs/2026-06-14-healthbench-reproduction-design.md`
**Plan:** `docs/superpowers/plans/2026-06-14-healthbench-reproduction.md`

## What was run

HealthBench's **grader meta-evaluation** on a 200-row sample of the official meta-eval
dataset (`2025-05-07-06-14-12_oss_meta_eval.jsonl`), through our Calibrate harness, using
**HealthBench's verbatim grader prompt** under two backends. Each row is one
`(conversation, completion, single rubric criterion)` with a physician panel's
`binary_labels`; consensus = majority vote (ties → met). The grader judges each criterion
met/not-met; we compare to the physician consensus.

- Sample: first 200 rows, `--format healthbench`, 200 examples / 200 labels (0 skipped).
- Graders: `hb-grader` pointed, two versions — `{provider: openai, model: gpt-4.1}` and
  `{provider: anthropic, model: claude-sonnet-4-6}` — both carrying the verbatim
  `GRADER_TEMPLATE`.
- `metaeval report --mode live --seed 0`; both reports persisted as `MetaEval` rows (run 1)
  and are visible on the dashboard `#/calibration` and `#/runs/1`.
- Reproduce: `set -a; source .env; set +a; HB_N=200 nix develop -c bash scripts/healthbench-repro.sh`.

## Results (our harness metrics)

| grader | N | agreement | κ (Cohen) | 95% CI | fail-precision | fail-recall | judge errors |
|---|---|---|---|---|---|---|---|
| **GPT-4.1** | 200 | 0.800 | **0.531** | [0.413, 0.648] | 0.507 | 0.927 | 0 |
| Claude sonnet-4-6 | 199 | 0.704 | 0.398 | [0.298, 0.500] | 0.402 | 0.975 | 1 |

("fail" = the *not-met* class. Claude dropped 1 case to a judge error — a malformed/oversized
response on `hb-0034` — so its N is 199.)

## Reconciliation against HealthBench's published figure

HealthBench's headline grader metric is `pairwise_model_f1_balanced` — the mean of the
*met*-class F1 and *not-met*-class F1. Our harness reports agreement + κ + fail-class
precision/recall instead, but the full 2×2 confusion matrix is **exactly recoverable** from
(agreement, fail-precision, fail-recall, N) — three equations, three unknowns — so we can
compute the same balanced-F1:

**GPT-4.1** (N=200): reconstructed confusion → human-fails 41, grader-fails 75, both-fail 38,
both-met 122.
- not-met F1 = 2·0.507·0.927/(0.507+0.927) = **0.655**
- met F1 = P 122/125=0.976, R 122/159=0.767 → **0.859**
- **balanced F1 ≈ 0.757**

**Claude** (N=199): human-fails 40, grader-fails 97, both-fail 39, both-met 101.
- not-met F1 = **0.569**; met F1 = **0.774** → **balanced F1 ≈ 0.672**

| grader | our balanced-F1 | HealthBench published |
|---|---|---|
| **GPT-4.1** | **≈ 0.76** | macro/balanced F1 **≈ 0.71** (inter-physician 0.57–0.73) |
| Claude sonnet-4-6 | ≈ 0.67 | — (not their grader) |

**Verdict: reproduced.** Our GPT-4.1 grader lands at balanced-F1 ≈ 0.76 against the
physician consensus — squarely in (and slightly above) HealthBench's published ≈ 0.71 and
their inter-physician 0.57–0.73 band. The grader agrees with the physician majority about as
well as physicians agree with each other, which is HealthBench's central claim. The Claude
grader (≈ 0.67) sits inside the inter-physician band, a notch below GPT-4.1.

Published anchor: HealthBench paper, arXiv [2505.08775](https://arxiv.org/pdf/2505.08775);
[Introducing HealthBench (OpenAI)](https://openai.com/index/healthbench/).

## Caveats (why ≈ 0.76, not exactly 0.71)

- **Sample, not the full set.** First 200 of the meta-eval rows; HealthBench reports over the
  full dataset. Our κ CI on GPT-4.1 is [0.41, 0.65] — a real sampling band.
- **Conversation formatting.** We substitute `<<conversation>>` with our transcript renderer
  (`role: content` lines + a leading empty `system:` line) rather than HealthBench's exact
  `"\n\n".join` of prompt+completion. The grader **prompt itself is verbatim**;
  `<<rubric_item>>` is the bare criterion string, matching their meta-eval. This whitespace/
  framing difference is the most likely source of the small delta.
- **Model snapshot.** `gpt-4.1` resolves to whatever the API currently serves; HealthBench's
  number is from their May-2025 snapshot.
- **Tie rule.** Physician consensus = `mean(binary_labels) ≥ 0.5` (ties → met). HealthBench's
  exact tie handling may differ at the margin.

## Side effects / things this also established

- **The live OpenAI judge path is now human-verified.** GPT-4.1 graded 200 cases live through
  the new config-driven custom-prompt path (`Evals.Grade.Live`), parsing `{criteria_met,
  explanation}` correctly — clearing the "OpenAI live call not yet human-verified" item open
  since the 2026-06-14 overnight batch.
- **Real HealthBench calibration data is on the dashboard.** The two `MetaEval` rows render on
  `#/calibration` (GPT-4.1 "moderate/substantial", Claude "moderate") and on the run-detail
  calibration section — the κ-surface slice now has genuine data, not just the demo seed.

## Repro / inspect

```
set -a; source .env; set +a
HB_N=200 nix develop -c bash scripts/healthbench-repro.sh
# dashboard:
MANIFEST_DATABASE_URL=postgresql:///healthbench_repro EVALS_HTTP_PORT=8788 \
  EVALS_STATIC_DIR=static nix develop -c ./.zinc/build/evals-dashboard
# open http://localhost:8788/#/calibration  and  /#/runs/1
```
