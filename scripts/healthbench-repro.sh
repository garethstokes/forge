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
