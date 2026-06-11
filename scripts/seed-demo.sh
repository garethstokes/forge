#!/usr/bin/env bash
# Seed a scratch database with demo data for the dashboard SPA.
#
# Creates (drop + recreate) the EVALS_DEMO_DB database (default: evals_demo)
# on the local postgres, migrates it via the manifest-evals CLI, then inserts:
#
#   - 1 dataset "demo" with 1 finalized version (v1) and 3 examples
#   - 1 target "gpt-mini" v1 (model claude-x), 1 grader "exactness" v1
#   - 2 succeeded runs over the same dataset version (so they are comparable),
#     with outputs for all examples — run 2's "capital-fr" output errors out
#     and one score on run 1 carries a grader error, to exercise the UI's
#     red-tinted rows and ⚠ score cells
#   - scores: run 1 = 1.0 / 1.0 / 0.0, run 2 = 1.0 / 0.0 / (errored)
#     (pass disagreement on "capital-de" exercises the compare .disagree row)
#   - run_metrics for both runs (the runs view metric chips)
#
# Requires: psql + a running postgres reachable as the current user (the nix
# devShell ships postgres 17), and a built CLI (nix develop -c zinc build).
#
# Usage:
#   nix develop -c bash scripts/seed-demo.sh
#   MANIFEST_DATABASE_URL="postgresql:///evals_demo" EVALS_HTTP_PORT=8788 \
#     EVALS_STATIC_DIR=static nix develop -c ./.zinc/build/evals-dashboard
#   open http://localhost:8788/#/runs
set -euo pipefail

cd "$(dirname "$0")/.."

DB="${EVALS_DEMO_DB:-evals_demo}"
URL="postgresql:///$DB"

dropdb --if-exists "$DB"
createdb "$DB"
MANIFEST_DATABASE_URL="$URL" ./.zinc/build/manifest-evals migrate

psql -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
INSERT INTO datasets (id, org, name, slug, created_at)
VALUES (1, 1, 'demo', 'demo', now() - interval '2 days');

INSERT INTO dataset_versions (id, dataset, version, note, finalized_at, created_at)
VALUES (1, 1, 1, 'demo seed', now() - interval '2 days', now() - interval '2 days');

INSERT INTO examples (id, dataset_version, key, input, expected) VALUES
  (1, 1, 'capital-fr', '{"q": "What is the capital of France?"}', '{"a": "Paris"}'),
  (2, 1, 'capital-de', '{"q": "What is the capital of Germany?"}', '{"a": "Berlin"}'),
  (3, 1, 'capital-au', '{"q": "What is the capital of Australia?"}', '{"a": "Canberra"}');

INSERT INTO targets (id, org, name, created_at)
VALUES (1, 1, 'gpt-mini', now() - interval '2 days');

INSERT INTO target_versions (id, target, version, model, prompt, params, created_at)
VALUES (1, 1, 1, 'claude-x', 'Answer the question concisely.', '{}', now() - interval '2 days');

INSERT INTO graders (id, org, name, kind, created_at)
VALUES (1, 1, 'exactness', 'exact', now() - interval '2 days');

INSERT INTO grader_versions (id, grader, version, config, created_at)
VALUES (1, 1, 1, '{"field": "a"}', now() - interval '2 days');

INSERT INTO runs (id, org, dataset_version, target_version, status, started_at, finished_at, created_at) VALUES
  (1, 1, 1, 1, 'succeeded', now() - interval '26 hours', now() - interval '25 hours', now() - interval '26 hours'),
  (2, 1, 1, 1, 'succeeded', now() - interval '2 hours',  now() - interval '1 hour',   now() - interval '2 hours');

INSERT INTO outputs (id, run, example, text, error, latency_ms, tokens) VALUES
  (1, 1, 1, 'Paris is the capital of France. It has been the political and cultural centre of the country for centuries, sitting on the Seine in the north of the country, and is home to roughly two million people within the city proper.', NULL, 812, '{"input": 18, "output": 52}'),
  (2, 1, 2, 'Berlin.', NULL, 401, '{"input": 18, "output": 4}'),
  (3, 1, 3, 'Sydney is the capital of Australia.', NULL, 633, '{"input": 18, "output": 9}'),
  (4, 2, 1, NULL, 'upstream timeout after 30s', 30000, NULL),
  (5, 2, 2, 'The capital of Germany is Bonn (since reunification the seat of government moved, but Bonn retains the title).', NULL, 922, '{"input": 18, "output": 28}'),
  (6, 2, 3, 'Canberra — often mistaken for Sydney or Melbourne — is the capital of Australia.', NULL, 540, '{"input": 18, "output": 18}');

INSERT INTO scores (id, output, grader_version, value, passed, detail, error, created_at) VALUES
  (1, 1, 1, 1.0, true,  '{"rationale": "mentions Paris"}',            NULL,                          now() - interval '24 hours'),
  (2, 2, 1, 1.0, true,  '{"rationale": "exact match"}',               NULL,                          now() - interval '24 hours'),
  (3, 3, 1, 0.0, false, '{"rationale": "Sydney is not the capital"}', NULL,                          now() - interval '24 hours'),
  (4, 4, 1, NULL, NULL, NULL,                                         'no output text to grade',     now() - interval '30 minutes'),
  (5, 5, 1, 0.0, false, '{"rationale": "Bonn is not the capital"}',   NULL,                          now() - interval '30 minutes'),
  (6, 6, 1, 1.0, true,  '{"rationale": "mentions Canberra"}',         NULL,                          now() - interval '30 minutes');

INSERT INTO run_metrics (id, run, grader_version, mean, pass_rate, count, computed_at) VALUES
  (1, 1, 1, 0.6666666666666666, 0.6666666666666666, 3, now() - interval '24 hours'),
  (2, 2, 1, 0.5,                0.5,                 2, now() - interval '30 minutes');

-- keep the sequences ahead of the explicit ids
SELECT setval('datasets_id_seq', 10), setval('dataset_versions_id_seq', 10),
       setval('examples_id_seq', 10), setval('targets_id_seq', 10),
       setval('target_versions_id_seq', 10), setval('graders_id_seq', 10),
       setval('grader_versions_id_seq', 10), setval('runs_id_seq', 10),
       setval('outputs_id_seq', 10), setval('scores_id_seq', 10),
       setval('run_metrics_id_seq', 10);
SQL

echo "seeded $DB. serve with:"
echo "  MANIFEST_DATABASE_URL=$URL EVALS_HTTP_PORT=8788 EVALS_STATIC_DIR=static nix develop -c ./.zinc/build/evals-dashboard"
