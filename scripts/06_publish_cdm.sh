#!/usr/bin/env bash
# M5: Publish mimiciv_etl.cdm_* tables as mimiciv_cdm.* views (rename + strip cdm_ prefix).
# Then add concept/vocabulary views and register source in WebAPI.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG=${PROJECT_ROOT}/logs/06_publish.log

docker exec -i broadsea-atlasdb psql -U postgres -d ohdsi -v ON_ERROR_STOP=1 <<'SQL' 2>&1 | tee "$LOG"
-- Drop any existing views/tables in mimiciv_cdm
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT table_name, table_type FROM information_schema.tables WHERE table_schema='mimiciv_cdm' LOOP
    IF r.table_type='VIEW' THEN
      EXECUTE format('DROP VIEW IF EXISTS mimiciv_cdm.%I CASCADE', r.table_name);
    ELSE
      EXECUTE format('DROP TABLE IF EXISTS mimiciv_cdm.%I CASCADE', r.table_name);
    END IF;
  END LOOP;
END $$;

-- CDM clinical tables: view mimiciv_cdm.foo -> mimiciv_etl.cdm_foo
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT table_name FROM information_schema.tables
            WHERE table_schema='mimiciv_etl'
              AND table_name LIKE 'cdm_%'
              AND table_type='BASE TABLE' LOOP
    EXECUTE format(
      'CREATE VIEW mimiciv_cdm.%I AS SELECT * FROM mimiciv_etl.%I',
      substring(r.table_name from 5),  -- strip 'cdm_' prefix
      r.table_name
    );
  END LOOP;
END $$;

-- Vocabulary tables: view mimiciv_cdm.concept -> mimiciv_voc.concept (Athena 6.3M)
CREATE VIEW mimiciv_cdm.concept              AS SELECT * FROM mimiciv_voc.concept;
CREATE VIEW mimiciv_cdm.vocabulary           AS SELECT * FROM mimiciv_voc.vocabulary;
CREATE VIEW mimiciv_cdm.domain               AS SELECT * FROM mimiciv_voc.domain;
CREATE VIEW mimiciv_cdm.concept_class        AS SELECT * FROM mimiciv_voc.concept_class;
CREATE VIEW mimiciv_cdm.relationship         AS SELECT * FROM mimiciv_voc.relationship;
CREATE VIEW mimiciv_cdm.concept_relationship AS SELECT * FROM mimiciv_voc.concept_relationship;
CREATE VIEW mimiciv_cdm.concept_ancestor     AS SELECT * FROM mimiciv_voc.concept_ancestor;
CREATE VIEW mimiciv_cdm.concept_synonym      AS SELECT * FROM mimiciv_voc.concept_synonym;
CREATE VIEW mimiciv_cdm.drug_strength        AS SELECT * FROM mimiciv_voc.drug_strength;

-- Final inventory
SELECT table_name, table_type FROM information_schema.tables
  WHERE table_schema='mimiciv_cdm' ORDER BY table_type, table_name;
SQL

echo "[$(date +%H:%M:%S)] Publish complete." | tee -a "$LOG"
