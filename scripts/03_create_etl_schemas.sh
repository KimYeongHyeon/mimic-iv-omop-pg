#!/usr/bin/env bash
# Create mimiciv_etl, mimiciv_voc, mimiciv_cdm schemas.
# - mimiciv_voc: views pointing at the existing Athena vocab (schema set by $VOCAB_SOURCE_SCHEMA)
# - mimiciv_etl: intermediate tables (src_*, lk_*, tmp_*, cdm_*)
# - mimiciv_cdm: final CDM unloaded for ATLAS
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LOG=${PROJECT_ROOT}/logs/03_etl_schemas.log

# Safety pre-check
EXISTING=$(docker exec broadsea-atlasdb psql -U postgres -d ohdsi -tAc \
  "select string_agg(schema_name, ',') from information_schema.schemata where schema_name in ('mimiciv_etl','mimiciv_voc','mimiciv_cdm');")
if [ -n "${EXISTING:-}" ]; then
  echo "ABORT: schema(s) already exist: $EXISTING" | tee -a "$LOG"
  exit 2
fi

# Verify source vocab schema exists and has 6.3M concepts
VOC_SOURCE="${VOCAB_SOURCE_SCHEMA:-omop_vocab}"
CNT=$(docker exec broadsea-atlasdb psql -U postgres -d ohdsi -tAc \
  "select count(*) from ${VOC_SOURCE}.concept;")
echo "[$(date +%H:%M:%S)] source vocab ${VOC_SOURCE}.concept count = $CNT" | tee -a "$LOG"
if [ "$CNT" -lt 1000000 ]; then
  echo "ABORT: source vocab is too small (need ~6.3M)" | tee -a "$LOG"
  exit 3
fi

docker exec -i broadsea-atlasdb psql -U postgres -d ohdsi -v ON_ERROR_STOP=1 <<SQL 2>&1 | tee -a "$LOG"
-- pgcrypto for gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA mimiciv_voc;
CREATE SCHEMA mimiciv_etl;
CREATE SCHEMA mimiciv_cdm;

-- vocab views (read-only, point at ${VOC_SOURCE})
CREATE VIEW mimiciv_voc.concept              AS SELECT * FROM ${VOC_SOURCE}.concept;
CREATE VIEW mimiciv_voc.vocabulary           AS SELECT * FROM ${VOC_SOURCE}.vocabulary;
CREATE VIEW mimiciv_voc.domain               AS SELECT * FROM ${VOC_SOURCE}.domain;
CREATE VIEW mimiciv_voc.concept_class        AS SELECT * FROM ${VOC_SOURCE}.concept_class;
CREATE VIEW mimiciv_voc.relationship         AS SELECT * FROM ${VOC_SOURCE}.relationship;
CREATE VIEW mimiciv_voc.concept_relationship AS SELECT * FROM ${VOC_SOURCE}.concept_relationship;
CREATE VIEW mimiciv_voc.concept_ancestor     AS SELECT * FROM ${VOC_SOURCE}.concept_ancestor;
CREATE VIEW mimiciv_voc.concept_synonym      AS SELECT * FROM ${VOC_SOURCE}.concept_synonym;
CREATE VIEW mimiciv_voc.drug_strength        AS SELECT * FROM ${VOC_SOURCE}.drug_strength;

-- voc_concept alias used by some OHDSI/MIMIC SQL files (lk_pat_ethnicity_concept etc.)
CREATE VIEW mimiciv_voc.voc_concept          AS SELECT * FROM ${VOC_SOURCE}.concept;
SQL

# Verify
docker exec broadsea-atlasdb psql -U postgres -d ohdsi -c "
SELECT n.nspname AS schema, count(c.oid) AS objects
FROM pg_namespace n
LEFT JOIN pg_class c ON c.relnamespace = n.oid AND c.relkind IN ('r','v')
WHERE n.nspname IN ('mimiciv_voc','mimiciv_etl','mimiciv_cdm')
GROUP BY n.nspname ORDER BY n.nspname;" | tee -a "$LOG"

# Verify view works
docker exec broadsea-atlasdb psql -U postgres -d ohdsi -c "SELECT count(*) FROM mimiciv_voc.concept;" | tee -a "$LOG"

echo "[$(date +%H:%M:%S)] schemas+views created" | tee -a "$LOG"
