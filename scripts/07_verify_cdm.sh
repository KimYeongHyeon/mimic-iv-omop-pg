#!/usr/bin/env bash
# CDM verification — 4 categories of checks, all SQL-only (no R/dependencies)
# Run time: ~30 seconds. For full validation use OHDSI DataQualityDashboard (separate setup).
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSQL="docker exec broadsea-atlasdb psql -U postgres -d ohdsi -X -A -t"

section() { echo; echo "================================================================"; echo "  $1"; echo "================================================================"; }

section "1. STRUCTURAL — all 38 CDM views present?"
$PSQL -c "
SELECT
  CASE WHEN cnt = 38 THEN 'PASS' ELSE 'FAIL' END || ': ' || cnt || ' / 38 views' AS result
FROM (
  SELECT count(*) AS cnt FROM information_schema.tables
  WHERE table_schema = 'mimiciv_cdm'
) t;
"

section "2. CARDINALITY — vs MIMIC-IV v2.2 source"
$PSQL -F $'\t' -c "
WITH expected_vs_observed AS (
  SELECT 'person'              AS tbl, 299712::bigint AS expected_min, (SELECT count(*) FROM mimiciv_cdm.person) AS observed
  UNION ALL SELECT 'visit_occurrence',    400000,  (SELECT count(*) FROM mimiciv_cdm.visit_occurrence)
  UNION ALL SELECT 'condition_occurrence', 100000, (SELECT count(*) FROM mimiciv_cdm.condition_occurrence)
  UNION ALL SELECT 'drug_exposure',        100000, (SELECT count(*) FROM mimiciv_cdm.drug_exposure)
  UNION ALL SELECT 'measurement',        10000000, (SELECT count(*) FROM mimiciv_cdm.measurement)
  UNION ALL SELECT 'death',                  1000, (SELECT count(*) FROM mimiciv_cdm.death)
)
SELECT
  tbl,
  observed,
  expected_min AS expected_min,
  CASE WHEN observed >= expected_min THEN 'PASS' ELSE 'FAIL ('||(expected_min-observed)||' short)' END AS verdict
FROM expected_vs_observed
ORDER BY observed DESC;
"

section "3. MAPPING QUALITY — % of records with target standard concept (concept_id > 0)"
$PSQL -F $'\t' -c "
WITH stats AS (
  SELECT 'condition_occurrence' AS tbl,
         count(*)                                     AS total,
         count(*) FILTER (WHERE condition_concept_id > 0)  AS mapped
  FROM mimiciv_cdm.condition_occurrence
  UNION ALL SELECT 'procedure_occurrence', count(*), count(*) FILTER (WHERE procedure_concept_id > 0)
    FROM mimiciv_cdm.procedure_occurrence
  UNION ALL SELECT 'measurement',          count(*), count(*) FILTER (WHERE measurement_concept_id > 0)
    FROM mimiciv_cdm.measurement
  UNION ALL SELECT 'drug_exposure',        count(*), count(*) FILTER (WHERE drug_concept_id > 0)
    FROM mimiciv_cdm.drug_exposure
  UNION ALL SELECT 'observation',          count(*), count(*) FILTER (WHERE observation_concept_id > 0)
    FROM mimiciv_cdm.observation
  UNION ALL SELECT 'device_exposure',      count(*), count(*) FILTER (WHERE device_concept_id > 0)
    FROM mimiciv_cdm.device_exposure
)
SELECT
  tbl,
  total,
  mapped,
  to_char((100.0 * mapped / NULLIF(total,0))::numeric, 'FM990.00') || '%' AS pct_mapped,
  CASE
    WHEN total = 0 THEN 'EMPTY'
    WHEN mapped::float / total >= 0.50 THEN 'PASS'
    WHEN mapped::float / total >= 0.20 THEN 'WARN'
    ELSE 'LOW'
  END AS verdict
FROM stats
ORDER BY (mapped::float / NULLIF(total,0)) DESC NULLS LAST;
"

section "4. REFERENTIAL INTEGRITY — FK orphans (should all be 0)"
$PSQL -F $'\t' -c "
SELECT 'visit.person'          AS edge,
       (SELECT count(*) FROM mimiciv_cdm.visit_occurrence v
        WHERE NOT EXISTS (SELECT 1 FROM mimiciv_cdm.person p WHERE p.person_id = v.person_id)) AS orphans
UNION ALL SELECT 'cond.person',
       (SELECT count(*) FROM mimiciv_cdm.condition_occurrence c
        WHERE NOT EXISTS (SELECT 1 FROM mimiciv_cdm.person p WHERE p.person_id = c.person_id))
UNION ALL SELECT 'meas.person',
       (SELECT count(*) FROM mimiciv_cdm.measurement m
        WHERE NOT EXISTS (SELECT 1 FROM mimiciv_cdm.person p WHERE p.person_id = m.person_id))
UNION ALL SELECT 'meas.visit',
       (SELECT count(*) FROM mimiciv_cdm.measurement m
        WHERE m.visit_occurrence_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM mimiciv_cdm.visit_occurrence v WHERE v.visit_occurrence_id = m.visit_occurrence_id))
UNION ALL SELECT 'drug.person',
       (SELECT count(*) FROM mimiciv_cdm.drug_exposure d
        WHERE NOT EXISTS (SELECT 1 FROM mimiciv_cdm.person p WHERE p.person_id = d.person_id));
"

section "5. DATE SANITY — visit_end >= visit_start (should be 0 violations)"
$PSQL -F $'\t' -c "
SELECT 'visit_end < visit_start' AS check,
       (SELECT count(*) FROM mimiciv_cdm.visit_occurrence
        WHERE visit_end_date < visit_start_date) AS violations
UNION ALL SELECT 'measurement before birth',
       (SELECT count(*) FROM mimiciv_cdm.measurement m
        JOIN mimiciv_cdm.person p USING (person_id)
        WHERE m.measurement_date < p.birth_datetime::date - INTERVAL '1 year')
UNION ALL SELECT 'death before last visit',
       (SELECT count(*) FROM mimiciv_cdm.death d
        JOIN (SELECT person_id, MAX(visit_end_date) max_visit FROM mimiciv_cdm.visit_occurrence GROUP BY 1) v USING (person_id)
        WHERE d.death_date < v.max_visit);
"

section "6. SAMPLE PATIENT — pull one person + all clinical events"
$PSQL -F $'\t' -c "
WITH p AS (SELECT person_id FROM mimiciv_cdm.person ORDER BY random() LIMIT 1)
SELECT 'person' AS what, person_id::text AS id, gender_concept_id::text AS detail, year_of_birth::text AS extra FROM mimiciv_cdm.person WHERE person_id IN (SELECT person_id FROM p)
UNION ALL SELECT 'visits',  person_id::text, COUNT(*)::text, MIN(visit_start_date)::text || ' .. ' || MAX(visit_end_date)::text
  FROM mimiciv_cdm.visit_occurrence WHERE person_id IN (SELECT person_id FROM p) GROUP BY 1,2
UNION ALL SELECT 'conditions', person_id::text, COUNT(*)::text, NULL
  FROM mimiciv_cdm.condition_occurrence WHERE person_id IN (SELECT person_id FROM p) GROUP BY 1,2
UNION ALL SELECT 'drugs', person_id::text, COUNT(*)::text, NULL
  FROM mimiciv_cdm.drug_exposure WHERE person_id IN (SELECT person_id FROM p) GROUP BY 1,2
UNION ALL SELECT 'measurements', person_id::text, COUNT(*)::text, NULL
  FROM mimiciv_cdm.measurement WHERE person_id IN (SELECT person_id FROM p) GROUP BY 1,2;
"

section "7. CONCEPT JOIN — top 10 conditions by frequency (uses vocabulary view)"
$PSQL -F $'\t' -c "
SELECT c.concept_name, c.vocabulary_id, n.cnt
FROM (
  SELECT condition_concept_id, count(*) cnt
  FROM mimiciv_cdm.condition_occurrence
  WHERE condition_concept_id > 0
  GROUP BY 1 ORDER BY 2 DESC LIMIT 10
) n
JOIN mimiciv_cdm.concept c ON c.concept_id = n.condition_concept_id;
"

section "DONE"
echo "All checks complete. For exhaustive validation, run OHDSI DataQualityDashboard:"
echo "  docker compose -f <broadsea_dir>/compose/dqd.yml up   (if configured)"
echo "or via R:"
echo "  R -e 'DataQualityDashboard::executeDqChecks(...mimiciv_cdm...)'"
