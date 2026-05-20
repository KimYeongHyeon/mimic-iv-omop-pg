#!/usr/bin/env bash
# Initialize mimiciv_cdm_results with WebAPI-expected tables.
# Required for ATLAS cohort generation, profiles, and Achilles output.
# Clones structure from an existing OHDSI results schema in the same DB.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LOG=${PROJECT_ROOT}/logs/08_results.log
TEMPLATE_SCHEMA="${RESULTS_TEMPLATE_SCHEMA:-synthea100k_results}"
TARGET_SCHEMA="${RESULTS_SCHEMA:-mimiciv_cdm_results}"

mkdir -p ${PROJECT_ROOT}/logs

# Verify template schema has the 36 cohort/achilles tables
COUNT=$(docker exec broadsea-atlasdb psql -U postgres -d ohdsi -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='${TEMPLATE_SCHEMA}' AND table_type='BASE TABLE';")
echo "[$(date +%H:%M:%S)] template ${TEMPLATE_SCHEMA}: ${COUNT} tables" | tee "$LOG"
if [ "$COUNT" -lt 30 ]; then
  echo "ERROR: template schema is too small. Set RESULTS_TEMPLATE_SCHEMA to a working OHDSI results schema." | tee -a "$LOG"
  exit 1
fi

# Dump template schema DDL, rewrite schema name, replay into target
docker exec broadsea-atlasdb bash -c "
pg_dump -U postgres -d ohdsi --schema-only --schema=${TEMPLATE_SCHEMA} --no-owner --no-acl 2>/dev/null \
  | sed 's/${TEMPLATE_SCHEMA}/${TARGET_SCHEMA}/g' \
  | psql -U postgres -d ohdsi -v ON_ERROR_STOP=0
" 2>&1 | tail -10 | tee -a "$LOG"

# Verify
docker exec broadsea-atlasdb psql -U postgres -d ohdsi -c "
SELECT count(*) AS tables_created FROM information_schema.tables
WHERE table_schema='${TARGET_SCHEMA}' AND table_type='BASE TABLE';" | tee -a "$LOG"

echo "[$(date +%H:%M:%S)] results schema initialized" | tee -a "$LOG"
