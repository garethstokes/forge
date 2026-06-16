#!/usr/bin/env bash
# Seed a scratch database with COHERENT demo data for the dashboard SPA.
#
# Creates (drop + recreate) the EVALS_DEMO_DB database (default: evals_demo)
# on the local postgres, migrates it via the manifest-evals CLI, then inserts a
# small "capital cities" eval whose data is internally consistent so the
# run-detail grader sections read correctly:
#
#   - 1 dataset "demo" v1 with 4 examples (capital-fr/de/au/jp). Each example
#     carries example_tags (theme:europe/oceania/asia) and a 3-criterion rubric
#     in `expected` (axis:accuracy / axis:conciseness / axis:clarity).
#   - 2 graders: "exactness" (exact — did it name the right capital?) and
#     "rubric" (pointed — the 3 axis-tagged criteria, partial credit).
#   - 2 runs over the same dataset version (comparable):
#       run 1 — full: exact + rubric scores on all 4 outputs.
#       run 2 — exact only; capital-de errored (red row / ⚠ cell), and
#               capital-au is RIGHT here (vs wrong in run 1) → a compare delta.
#   - run_metrics derived from those scores so the breakdown reconciles:
#       rubric run-1 overall μ 0.70; themes europe .75 (n2) / oceania .5 / asia
#       .8; axes accuracy .75 / conciseness .75 / clarity .50 (all n4) — i.e.
#       the breakdown axes are exactly the rubric's 3 criteria, and the themes
#       are exactly the examples' example_tags.
#
# Requires: psql + a running postgres reachable as the current user (the nix
# devShell ships postgres 17), and a built CLI (nix develop -c zinc build).
#
# Usage:
#   nix develop -c bash scripts/seed-demo.sh
#   MANIFEST_DATABASE_URL="postgresql:///evals_demo" EVALS_HTTP_PORT=8787 \
#     EVALS_STATIC_DIR=static nix develop -c ./.zinc/build/evals-dashboard
#   open http://localhost:8787/#/runs
set -euo pipefail

cd "$(dirname "$0")/.."

DB="${EVALS_DEMO_DB:-evals_demo}"
URL="postgresql:///$DB"

# Safety guard: refuse to drop any database whose name doesn't contain "demo"
case "$DB" in
  *demo*) ;;
  *) echo "refusing: \$EVALS_DEMO_DB must contain 'demo' (got: $DB)"; exit 1;;
esac

# --force terminates lingering connections (e.g. a dashboard server still
# holding its pool) instead of failing with "being accessed by other users".
dropdb --if-exists --force "$DB"
createdb "$DB"
MANIFEST_DATABASE_URL="$URL" ./.zinc/build/manifest-evals migrate

psql -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
INSERT INTO orgs (id, slug, name, created_at)
VALUES (1, 'acme', 'Acme', now()), (2, 'globex', 'Globex', now());

INSERT INTO datasets (id, org, name, slug, created_at)
VALUES (1, 1, 'demo', 'demo', now() - interval '2 days');

INSERT INTO dataset_versions (id, org, dataset, version, note, finalized_at, created_at)
VALUES (1, 1, 1, 1, 'demo seed', now() - interval '2 days', now() - interval '2 days');

-- Each example's `expected` is its 3-criterion rubric (axis-tagged); `meta`
-- carries the example's theme tag. (All four examples share the same rubric so
-- the run-level criteria union is the 3 criteria.)
INSERT INTO examples (id, org, dataset_version, key, input, expected, meta) VALUES
  (1, 1, 1, 'capital-fr', '{"messages": [{"role": "user", "content": "What is the capital of France?"}]}',
     '[{"criterion":"names the correct capital","points":5,"tags":["axis:accuracy"]},{"criterion":"is concise","points":3,"tags":["axis:conciseness"]},{"criterion":"explicitly states it is the capital","points":2,"tags":["axis:clarity"]}]',
     '{"example_tags":["theme:europe"]}'),
  (2, 1, 1, 'capital-de', '{"messages": [{"role": "user", "content": "What is the capital of Germany?"}]}',
     '[{"criterion":"names the correct capital","points":5,"tags":["axis:accuracy"]},{"criterion":"is concise","points":3,"tags":["axis:conciseness"]},{"criterion":"explicitly states it is the capital","points":2,"tags":["axis:clarity"]}]',
     '{"example_tags":["theme:europe"]}'),
  (3, 1, 1, 'capital-au', '{"messages": [{"role": "user", "content": "What is the capital of Australia?"}]}',
     '[{"criterion":"names the correct capital","points":5,"tags":["axis:accuracy"]},{"criterion":"is concise","points":3,"tags":["axis:conciseness"]},{"criterion":"explicitly states it is the capital","points":2,"tags":["axis:clarity"]}]',
     '{"example_tags":["theme:oceania"]}'),
  (4, 1, 1, 'capital-jp', '{"messages": [{"role": "user", "content": "What is the capital of Japan?"}]}',
     '[{"criterion":"names the correct capital","points":5,"tags":["axis:accuracy"]},{"criterion":"is concise","points":3,"tags":["axis:conciseness"]},{"criterion":"explicitly states it is the capital","points":2,"tags":["axis:clarity"]}]',
     '{"example_tags":["theme:asia"]}');

INSERT INTO targets (id, org, name, created_at)
VALUES (1, 1, 'gpt-mini', now() - interval '2 days');

INSERT INTO target_versions (id, org, target, version, model, prompt, params, created_at)
VALUES (1, 1, 1, 1, 'claude-x', 'Answer the question concisely.', '{}', now() - interval '2 days');

INSERT INTO graders (id, org, name, kind, created_at) VALUES
  (1, 1, 'exactness', 'exact',   now() - interval '2 days'),
  (2, 1, 'rubric',    'pointed', now() - interval '2 days');

INSERT INTO grader_versions (id, org, grader, version, config, created_at) VALUES
  (1, 1, 1, 1, '{"field": "a"}', now() - interval '2 days'),
  (2, 1, 2, 1, '{"votes": 1}',   now() - interval '2 days');

INSERT INTO runs (id, org, dataset_version, target_version, status, started_at, finished_at, created_at) VALUES
  (1, 1, 1, 1, 'succeeded', now() - interval '26 hours', now() - interval '25 hours', now() - interval '26 hours'),
  (2, 1, 1, 1, 'succeeded', now() - interval '2 hours',  now() - interval '1 hour',   now() - interval '2 hours');

INSERT INTO outputs (id, org, run, example, text, error, latency_ms, tokens) VALUES
  -- run 1
  (1, 1, 1, 1, 'Paris is the capital of France. It has been the political and cultural centre of the country for centuries, sitting on the Seine in the north of the country, and is home to roughly two million people within the city proper.', NULL, 812, '{"input": 18, "output": 52}'),
  (2, 1, 1, 2, 'Berlin.', NULL, 401, '{"input": 18, "output": 4}'),
  (3, 1, 1, 3, 'Sydney is the capital of Australia.', NULL, 633, '{"input": 18, "output": 9}'),
  (4, 1, 1, 4, 'Tokyo.', NULL, 388, '{"input": 18, "output": 4}'),
  -- run 2 (capital-de errored; capital-au is correct this time)
  (5, 1, 2, 1, 'Paris.', NULL, 210, '{"input": 18, "output": 3}'),
  (6, 1, 2, 2, NULL, 'upstream timeout after 30s', 30000, NULL),
  (7, 1, 2, 3, 'Canberra is the capital of Australia.', NULL, 540, '{"input": 18, "output": 8}'),
  (8, 1, 2, 4, 'Tokyo.', NULL, 305, '{"input": 18, "output": 4}');

-- exact grader: did the answer name the right capital? (1 / 0)
INSERT INTO scores (id, org, output, grader_version, value, passed, detail, error, created_at) VALUES
  -- run 1: fr✓ de✓ au✗(Sydney) jp✓  → μ 0.75, pass 75%
  (1, 1, 1, 1, 1.0, true,  '{"rationale": "names Paris"}',              NULL,                      now() - interval '24 hours'),
  (2, 1, 2, 1, 1.0, true,  '{"rationale": "names Berlin"}',             NULL,                      now() - interval '24 hours'),
  (3, 1, 3, 1, 0.0, false, '{"rationale": "Sydney is not the capital"}',NULL,                      now() - interval '24 hours'),
  (4, 1, 4, 1, 1.0, true,  '{"rationale": "names Tokyo"}',              NULL,                      now() - interval '24 hours'),
  -- run 2: fr✓ de=errored au✓(Canberra) jp✓  → μ 1.0, pass 100% (3 scored)
  (5, 1, 5, 1, 1.0, true,  '{"rationale": "names Paris"}',              NULL,                      now() - interval '30 minutes'),
  (6, 1, 6, 1, NULL, NULL, NULL,                                        'no output text to grade', now() - interval '30 minutes'),
  (7, 1, 7, 1, 1.0, true,  '{"rationale": "names Canberra"}',           NULL,                      now() - interval '30 minutes'),
  (8, 1, 8, 1, 1.0, true,  '{"rationale": "names Tokyo"}',              NULL,                      now() - interval '30 minutes');

-- rubric grader (pointed) on run 1: per-criterion verdicts. The detail.criteria
-- drive both the run-level criteria union and (Slice B) the per-answer view.
-- Met pattern → axis means: accuracy .75 (au wrong), conciseness .75 (fr long),
-- clarity .50 (de & jp don't say "is the capital"). Per-example values:
-- fr .7, de .8, au .5, jp .8 → overall .70; europe .75, oceania .5, asia .8.
INSERT INTO scores (id, org, output, grader_version, value, passed, detail, error, created_at) VALUES
  (9,  1, 1, 2, 0.7, NULL, '{"achieved":7,"possible":10,"criteria":[{"criterion":"names the correct capital","points":5,"tags":["axis:accuracy"],"met":true,"explanation":"names Paris"},{"criterion":"is concise","points":3,"tags":["axis:conciseness"],"met":false,"explanation":"a full paragraph — not concise"},{"criterion":"explicitly states it is the capital","points":2,"tags":["axis:clarity"],"met":true,"explanation":"says it is the capital of France"}]}', NULL, now() - interval '24 hours'),
  (10, 1, 2, 2, 0.8, NULL, '{"achieved":8,"possible":10,"criteria":[{"criterion":"names the correct capital","points":5,"tags":["axis:accuracy"],"met":true,"explanation":"names Berlin"},{"criterion":"is concise","points":3,"tags":["axis:conciseness"],"met":true,"explanation":"a single word"},{"criterion":"explicitly states it is the capital","points":2,"tags":["axis:clarity"],"met":false,"explanation":"does not say it is the capital"}]}', NULL, now() - interval '24 hours'),
  (11, 1, 3, 2, 0.5, NULL, '{"achieved":5,"possible":10,"criteria":[{"criterion":"names the correct capital","points":5,"tags":["axis:accuracy"],"met":false,"explanation":"Sydney is not the capital — Canberra is"},{"criterion":"is concise","points":3,"tags":["axis:conciseness"],"met":true,"explanation":"one short sentence"},{"criterion":"explicitly states it is the capital","points":2,"tags":["axis:clarity"],"met":true,"explanation":"says it is the capital of Australia"}]}', NULL, now() - interval '24 hours'),
  (12, 1, 4, 2, 0.8, NULL, '{"achieved":8,"possible":10,"criteria":[{"criterion":"names the correct capital","points":5,"tags":["axis:accuracy"],"met":true,"explanation":"names Tokyo"},{"criterion":"is concise","points":3,"tags":["axis:conciseness"],"met":true,"explanation":"a single word"},{"criterion":"explicitly states it is the capital","points":2,"tags":["axis:clarity"],"met":false,"explanation":"does not say it is the capital"}]}', NULL, now() - interval '24 hours');

-- exact grader overall metrics (no tags)
INSERT INTO run_metrics (id, org, run, grader_version, mean, pass_rate, count, computed_at, tag, stderr) VALUES
  (1, 1, 1, 1, 0.75, 0.75, 4, now() - interval '24 hours',  NULL, NULL),
  (2, 1, 2, 1, 1.0,  1.0,  3, now() - interval '30 minutes', NULL, NULL);

-- rubric grader on run 1: overall + per-theme + per-axis breakdowns, all
-- derived from the per-criterion scores above (themes from example_tags, axes
-- from the criteria tags). stderr values are illustrative bootstrap SEs.
INSERT INTO run_metrics (id, org, run, grader_version, mean, pass_rate, count, computed_at, tag, stderr) VALUES
  (3, 1, 1, 2, 0.70, NULL, 4, now() - interval '24 hours', NULL,               0.07),
  (4, 1, 1, 2, 0.75, NULL, 2, now() - interval '24 hours', 'theme:europe',     0.05),
  (5, 1, 1, 2, 0.50, NULL, 1, now() - interval '24 hours', 'theme:oceania',    NULL),
  (6, 1, 1, 2, 0.80, NULL, 1, now() - interval '24 hours', 'theme:asia',       NULL),
  (7, 1, 1, 2, 0.75, NULL, 4, now() - interval '24 hours', 'axis:accuracy',    0.22),
  (8, 1, 1, 2, 0.75, NULL, 4, now() - interval '24 hours', 'axis:conciseness', 0.22),
  (9, 1, 1, 2, 0.50, NULL, 4, now() - interval '24 hours', 'axis:clarity',     0.25);

-- meta-eval calibration history (append-only; keyed by run + grader_version).
-- grader_version 1 = exactness/exact, 2 = rubric/pointed. Two computedAt points
-- per grader so the run-detail sparkline shows a trend. exactness climbs and its
-- 95% CI lower bound clears the 0.6 trust threshold (→ "trustworthy", green);
-- rubric sits borderline with its CI low below 0.6 (→ "below threshold", amber).
INSERT INTO meta_evals
  (id, org, run, grader_version, mode, seed, agreement, kappa, kappa_low, kappa_high,
   fail_precision, fail_recall, pass_f1, fail_f1, balanced_f1, measured, judge_errors, computed_at) VALUES
  -- exactness (gv 1): trustworthy, rising. balanced_f1 = (pass_f1 + fail_f1)/2
  (1, 1, 1, 1, 'stored', 1, 0.86, 0.70, 0.58, 0.82, 0.83, 0.80, 0.88, 0.78, 0.83, 4, '[]', now() - interval '25 hours'),
  (2, 1, 2, 1, 'stored', 1, 0.92, 0.80, 0.66, 0.92, 0.88, 0.85, 0.92, 0.80, 0.86, 4, '[]', now() - interval '1 hour'),
  -- rubric (gv 2): borderline, below threshold
  (3, 1, 1, 2, 'stored', 1, 0.74, 0.52, 0.34, 0.70, 0.66, 0.60, 0.66, 0.54, 0.60, 4, '["capital-au"]', now() - interval '25 hours'),
  (4, 1, 2, 2, 'stored', 1, 0.78, 0.55, 0.38, 0.72, 0.70, 0.64, 0.70, 0.58, 0.64, 4, '[]', now() - interval '1 hour');

-- second-org dataset so isolation is visible in comparisons
INSERT INTO datasets (id, org, name, slug, created_at)
VALUES (100, 2, 'globex-demo', 'globex-demo', now());

-- keep the sequences ahead of the explicit ids
SELECT setval('orgs_id_seq', 10),
       setval('datasets_id_seq', 110), setval('dataset_versions_id_seq', 10),
       setval('examples_id_seq', 10), setval('targets_id_seq', 10),
       setval('target_versions_id_seq', 10), setval('graders_id_seq', 10),
       setval('grader_versions_id_seq', 10), setval('runs_id_seq', 10),
       setval('outputs_id_seq', 10), setval('scores_id_seq', 20),
       setval('run_metrics_id_seq', 10), setval('meta_evals_id_seq', 10);
SQL

echo "seeded $DB. serve with:"
echo "  MANIFEST_DATABASE_URL=$URL EVALS_HTTP_PORT=8787 EVALS_STATIC_DIR=static nix develop -c ./.zinc/build/evals-dashboard"
