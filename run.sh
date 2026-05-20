#!/usr/bin/env bash
# mimic-iv-omop-pg — End-to-end MIMIC-IV → OMOP CDM v5.3.1 (PostgreSQL)
#
# Usage:
#   ./run.sh                  # run all phases (idempotent)
#   ./run.sh m1               # run phase M1 only (loads raw)
#   ./run.sh m2-m5            # run phases M2 through M5
#   ./run.sh verify           # run only the verification report
#
# Phases:
#   m0  prerequisites check
#   m1  load raw MIMIC-IV into mimiciv_hosp/icu/note (~30 min)
#   m2  port OHDSI/MIMIC BigQuery SQL → PostgreSQL
#   m3  create etl/voc/cdm schemas (+ pgcrypto, vocab views)
#   m4  load custom MIMIC vocab (gcpt_* mappings)
#   m5  run full ETL chain (36 SQL files) (~2-3 h)
#   m6  publish mimiciv_cdm views + register in WebAPI
#   m7  verify CDM quality (structural / cardinality / mapping / FK)
#   m8  init results schema for ATLAS cohort/profiles (36 tables)
#   m9  run Achilles characterization (~1.5-3 h) — enables ATLAS dashboards
#
set -euo pipefail
cd "$(dirname "$0")"
PHASE="${1:-all}"
mkdir -p logs

# --- shared env ---
export ATLASDB_CONTAINER="${ATLASDB_CONTAINER:-broadsea-atlasdb}"
export ATLASDB_NETWORK="${ATLASDB_NETWORK:-broadsea_default}"
export ATLASDB_USER="${ATLASDB_USER:-postgres}"
export ATLASDB_PASS="${ATLASDB_PASS:-mypass}"  # Broadsea documented default; override via env
export ATLASDB_DB="${ATLASDB_DB:-ohdsi}"
export VOCAB_SOURCE_SCHEMA="${VOCAB_SOURCE_SCHEMA:-synthea_cdm_aristotle}"
export MIMIC_DATA_DIR="${MIMIC_DATA_DIR:-$PWD/data/MIMIC-IV-2.2}"
export OHDSI_MIMIC_DIR="${OHDSI_MIMIC_DIR:-$PWD/ohdsi-mimic}"
export MIMIC_CODE_DIR="${MIMIC_CODE_DIR:-$PWD/mimic-code}"

# --- helpers ---
PSQL_CMD() { docker exec "$ATLASDB_CONTAINER" psql -U "$ATLASDB_USER" -d "$ATLASDB_DB" "$@"; }
SIDE_PSQL() {
  docker run --rm -i \
    --network "$ATLASDB_NETWORK" \
    -e PGPASSWORD="$ATLASDB_PASS" \
    "$@" \
    postgres:16-alpine \
    psql -h "$ATLASDB_CONTAINER" -U "$ATLASDB_USER" -d "$ATLASDB_DB" -v ON_ERROR_STOP=1
}

# --- phases ---
m0_check() {
  echo "=== M0: Prerequisites ==="
  docker ps --filter "name=$ATLASDB_CONTAINER" --format '{{.Names}}' | grep -q "$ATLASDB_CONTAINER" \
    || { echo "ERROR: container $ATLASDB_CONTAINER not running"; exit 1; }
  PSQL_CMD -tAc "SELECT 1;" > /dev/null
  PSQL_CMD -tAc "SELECT count(*) FROM ${VOCAB_SOURCE_SCHEMA}.concept;" \
    | awk '$1<1000000{print "ERROR: ", $1, " concepts in ${VOCAB_SOURCE_SCHEMA} (need 6M+ from Athena)"; exit 1}{print "  vocab OK: " $1 " concepts"}'
  test -f MIMIC-IV-2.2.zip || test -d "$MIMIC_DATA_DIR" \
    || { echo "ERROR: place MIMIC-IV-2.2.zip in $PWD or extract to data/MIMIC-IV-2.2/"; exit 1; }
  test -d "$OHDSI_MIMIC_DIR" \
    || git clone --depth 1 https://github.com/OHDSI/MIMIC.git "$OHDSI_MIMIC_DIR"
  test -d "$MIMIC_CODE_DIR" \
    || git clone --depth 1 https://github.com/MIT-LCP/mimic-code.git "$MIMIC_CODE_DIR"
  echo "  M0 OK"
}

m1_load_raw() {
  echo "=== M1: Load raw MIMIC-IV ==="
  if [ ! -d "$MIMIC_DATA_DIR" ]; then
    test -f MIMIC-IV-2.2.zip || { echo "missing MIMIC-IV-2.2.zip"; exit 1; }
    echo "  unzipping..."
    unzip -o MIMIC-IV-2.2.zip -d data/ > logs/unzip.log 2>&1
  fi
  ./scripts/01_create_schema.sh
  ./scripts/02a_load_small.sh
  ./scripts/02b_load_large.sh
}

m2_port_sql() {
  echo "=== M2: Port OHDSI/MIMIC SQL → Postgres ==="
  mkdir -p etl/00_ddl etl/01_staging etl/02_etl
  for f in "$OHDSI_MIMIC_DIR"/etl/etl/*.sql; do
    python3 scripts/bq_to_pg.py "$f" "etl/02_etl/$(basename $f)"
  done
  for f in "$OHDSI_MIMIC_DIR"/etl/staging/st_{core,hosp,icu}.sql \
           "$OHDSI_MIMIC_DIR"/etl/staging/voc_copy_to_target_dataset.sql; do
    [ -f "$f" ] && python3 scripts/bq_to_pg.py "$f" "etl/01_staging/$(basename $f)"
  done
  for f in "$OHDSI_MIMIC_DIR"/etl/ddl/*.sql; do
    python3 scripts/bq_to_pg.py "$f" "etl/00_ddl/$(basename $f)"
  done
  # Apply manual patches
  [ -d patches ] && for p in patches/*.patch; do
    [ -f "$p" ] && patch -p1 < "$p" || true
  done
  echo "  $(find etl -name '*.sql' | wc -l) SQL files converted"
}

m3_schemas() {
  echo "=== M3: Create schemas + DDL ==="
  ./scripts/03_create_etl_schemas.sh
  cat etl/00_ddl/ddl_cdm_5_3_1.sql | SIDE_PSQL > logs/m3_ddl.log
}

m4_custom_vocab() {
  echo "=== M4: Load custom MIMIC vocabulary ==="
  ./scripts/04_load_custom_vocab.sh
}

m5_etl() {
  echo "=== M5: Run ETL chain ==="
  ./scripts/05_run_etl.sh
}

m6_publish() {
  echo "=== M6: Publish + register ==="
  ./scripts/06_publish_cdm.sh
  echo "  Optional: register source in WebAPI — see docs/WEBAPI_REGISTER.md"
}

m7_verify() {
  echo "=== M7: Verify CDM ==="
  ./scripts/07_verify_cdm.sh
}

m8_results_schema() {
  echo "=== M8: Init results schema (ATLAS cohort/profile tables) ==="
  ./scripts/08_init_results_schema.sh
}

m9_achilles() {
  echo "=== M9: Run Achilles characterization (~1.5-3 h) ==="
  ./scripts/09_run_achilles.sh
}

case "$PHASE" in
  m0|check)       m0_check ;;
  m1)             m0_check; m1_load_raw ;;
  m2)             m2_port_sql ;;
  m3)             m3_schemas ;;
  m4)             m4_custom_vocab ;;
  m5)             m5_etl ;;
  m6|publish)     m6_publish ;;
  m7|verify)      m7_verify ;;
  m8|results)     m8_results_schema ;;
  m9|achilles)    m9_achilles ;;
  m1-m2)          m0_check; m1_load_raw; m2_port_sql ;;
  m2-m5)          m2_port_sql; m3_schemas; m4_custom_vocab; m5_etl ;;
  m8-m9)          m8_results_schema; m9_achilles ;;
  all|"")         m0_check; m1_load_raw; m2_port_sql; m3_schemas; m4_custom_vocab; m5_etl; m6_publish; m7_verify; m8_results_schema; m9_achilles ;;
  *)              echo "usage: $0 [m0|m1|m2|m3|m4|m5|m6|m7|m8|m9|all]"; exit 2 ;;
esac

echo
echo "DONE: phase=$PHASE"
