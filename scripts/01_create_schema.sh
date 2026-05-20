#!/usr/bin/env bash
# M1 step: create MIMIC-IV native schemas (mimiciv_hosp, mimiciv_icu, mimiciv_derived)
# Uses sidecar postgres:16-alpine container to avoid host psql dependency.
# Safety: schemas are confirmed non-existent before running.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LOG=${PROJECT_ROOT}/logs/01_create.log

# Safety pre-check: refuse if any mimiciv_* schema already exists
EXISTING=$(docker exec broadsea-atlasdb psql -U postgres -d ohdsi -tAc \
  "select schema_name from information_schema.schemata where schema_name in ('mimiciv_hosp','mimiciv_icu','mimiciv_derived','mimiciv_note');")
if [ -n "$EXISTING" ]; then
  echo "ABORT: mimiciv_* schema(s) already exist: $EXISTING" | tee -a "$LOG"
  echo "Inspect/backup them first. Refusing to DROP CASCADE." | tee -a "$LOG"
  exit 2
fi

# Run create.sql for hosp/icu via sidecar
docker run --rm \
  --network broadsea_default \
  -v ${PROJECT_ROOT}/mimic-code/mimic-iv/buildmimic/postgres:/scripts:ro \
  -e PGPASSWORD="${ATLASDB_PASS:?ATLASDB_PASS env required}" \
  postgres:16-alpine \
  psql -h broadsea-atlasdb -U postgres -d ohdsi \
       -v ON_ERROR_STOP=1 \
       -f /scripts/create.sql 2>&1 | tee -a "$LOG"

# Run create.sql for note module
docker run --rm \
  --network broadsea_default \
  -v ${PROJECT_ROOT}/mimic-code/mimic-iv-note/buildmimic/postgres:/scripts:ro \
  -e PGPASSWORD="${ATLASDB_PASS:?ATLASDB_PASS env required}" \
  postgres:16-alpine \
  psql -h broadsea-atlasdb -U postgres -d ohdsi \
       -v ON_ERROR_STOP=1 \
       -f /scripts/create.sql 2>&1 | tee -a "$LOG"

# Verify
docker exec broadsea-atlasdb psql -U postgres -d ohdsi -c "
SELECT n.nspname AS schema, count(c.oid) AS tables
FROM pg_namespace n
LEFT JOIN pg_class c ON c.relnamespace = n.oid AND c.relkind='r'
WHERE n.nspname LIKE 'mimiciv%'
GROUP BY n.nspname ORDER BY n.nspname;" 2>&1 | tee -a "$LOG"

echo "$(date +%H:%M:%S) DONE: schemas created" | tee -a "$LOG"
