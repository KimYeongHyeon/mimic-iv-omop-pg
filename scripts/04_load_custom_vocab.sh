#!/usr/bin/env bash
# Load OHDSI/MIMIC custom_mapping_csv/ into a mimiciv_custom schema, then expose via voc_* views.
# Fixes the 0% measurement_concept_id mapping (chartevents itemids etc).
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CSV_DIR=${PROJECT_ROOT}/ohdsi-mimic/custom_mapping_csv
LOG=${PROJECT_ROOT}/logs/04_custom_vocab.log

docker exec -i broadsea-atlasdb psql -U postgres -d ohdsi -v ON_ERROR_STOP=1 <<'SQL' 2>&1 | tee "$LOG"
-- Custom mappings schema
DROP SCHEMA IF EXISTS mimiciv_custom CASCADE;
CREATE SCHEMA mimiciv_custom;

-- raw CSV staging
CREATE TABLE mimiciv_custom.raw_csv (
  concept_name                    text,
  source_concept_id               bigint,
  source_vocabulary_id            text,
  source_domain_id                text,
  source_concept_class_id         text,
  standard_concept                text,
  concept_code                    text,
  valid_start_date                date,
  valid_end_date                  date,
  invalid_reason                  text,
  target_concept_id               bigint,
  relationship_id                 text,
  reverse_relationship_id         text,
  relationship_valid_start_date   date,
  relationship_end_date           date,
  invalid_reason_cr               text
);
SQL

# Load each CSV (skip non-mapping files)
for f in "$CSV_DIR"/gcpt_*.csv; do
  bn=$(basename "$f")
  echo "[$(date +%H:%M:%S)] LOAD $bn"
  docker run --rm \
    --network broadsea_default \
    -v "$CSV_DIR:/csv:ro" \
    -e PGPASSWORD="${ATLASDB_PASS:?ATLASDB_PASS env required}" \
    postgres:16-alpine \
    psql -h broadsea-atlasdb -U postgres -d ohdsi -v ON_ERROR_STOP=1 \
      -c "\\copy mimiciv_custom.raw_csv FROM '/csv/$bn' WITH (FORMAT csv, HEADER true, NULL '')" \
    2>&1 | tail -3
done

# Build the OMOP-compatible concept + concept_relationship tables
docker exec -i broadsea-atlasdb psql -U postgres -d ohdsi -v ON_ERROR_STOP=1 <<'SQL' 2>&1 | tee -a "$LOG"
-- Concepts: deduplicated source concepts from custom CSVs
DROP TABLE IF EXISTS mimiciv_custom.concept CASCADE;
CREATE TABLE mimiciv_custom.concept AS
SELECT DISTINCT
  source_concept_id      AS concept_id,
  concept_name           AS concept_name,
  source_domain_id       AS domain_id,
  source_vocabulary_id   AS vocabulary_id,
  source_concept_class_id AS concept_class_id,
  standard_concept       AS standard_concept,
  concept_code           AS concept_code,
  COALESCE(valid_start_date, '1970-01-01'::date) AS valid_start_date,
  COALESCE(valid_end_date,   '2099-12-31'::date) AS valid_end_date,
  invalid_reason         AS invalid_reason
FROM mimiciv_custom.raw_csv
WHERE source_concept_id IS NOT NULL;

-- Concept relationships: source -> target (Maps to)
DROP TABLE IF EXISTS mimiciv_custom.concept_relationship CASCADE;
CREATE TABLE mimiciv_custom.concept_relationship AS
SELECT DISTINCT
  source_concept_id                            AS concept_id_1,
  target_concept_id                            AS concept_id_2,
  relationship_id                              AS relationship_id,
  COALESCE(relationship_valid_start_date, '1970-01-01'::date) AS valid_start_date,
  COALESCE(relationship_end_date,         '2099-12-31'::date) AS valid_end_date,
  invalid_reason_cr                            AS invalid_reason
FROM mimiciv_custom.raw_csv
WHERE source_concept_id IS NOT NULL
  AND target_concept_id IS NOT NULL
  AND relationship_id IS NOT NULL;

-- Stats
SELECT 'concepts'              AS what, count(*) AS n FROM mimiciv_custom.concept
UNION ALL
SELECT 'concept_relationships',         count(*) FROM mimiciv_custom.concept_relationship
UNION ALL
SELECT 'distinct vocabularies',         count(DISTINCT vocabulary_id) FROM mimiciv_custom.concept;
SQL

# Replace voc_concept and voc_concept_relationship views with UNION of standard + custom
docker exec -i broadsea-atlasdb psql -U postgres -d ohdsi -v ON_ERROR_STOP=1 <<'SQL' 2>&1 | tee -a "$LOG"
DROP VIEW IF EXISTS mimiciv_etl.voc_concept CASCADE;
CREATE VIEW mimiciv_etl.voc_concept AS
  SELECT concept_id, concept_name, domain_id, vocabulary_id, concept_class_id,
         standard_concept, concept_code, valid_start_date, valid_end_date, invalid_reason
  FROM mimiciv_voc.concept
  UNION ALL
  SELECT concept_id, concept_name, domain_id, vocabulary_id, concept_class_id,
         standard_concept, concept_code, valid_start_date, valid_end_date, invalid_reason
  FROM mimiciv_custom.concept;

DROP VIEW IF EXISTS mimiciv_etl.voc_concept_relationship CASCADE;
CREATE VIEW mimiciv_etl.voc_concept_relationship AS
  SELECT concept_id_1, concept_id_2, relationship_id, valid_start_date, valid_end_date, invalid_reason
  FROM mimiciv_voc.concept_relationship
  UNION ALL
  SELECT concept_id_1, concept_id_2, relationship_id, valid_start_date, valid_end_date, invalid_reason
  FROM mimiciv_custom.concept_relationship;

-- Verify count
SELECT 'voc_concept' AS view, count(*) AS rows FROM mimiciv_etl.voc_concept
UNION ALL
SELECT 'voc_concept_relationship', count(*) FROM mimiciv_etl.voc_concept_relationship;
SQL

echo "[$(date +%H:%M:%S)] custom vocab loaded" | tee -a "$LOG"
