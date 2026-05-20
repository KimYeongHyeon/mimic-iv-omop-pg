#!/usr/bin/env bash
# Stage A: load small/medium MIMIC-IV tables (< 100 MB compressed each).
# These should complete in minutes total. Used to fail-fast on schema mismatches.
# Strategy: per-table \copy via psql in sidecar container.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DATA_DIR=${PROJECT_ROOT}/data/MIMIC-IV-2.2
LOG_DIR=${PROJECT_ROOT}/logs
mkdir -p "$LOG_DIR/load"

# table_def lines: schema|table|module|file
TABLES=(
  "mimiciv_hosp|d_hcpcs|hosp|d_hcpcs.csv.gz"
  "mimiciv_hosp|d_icd_diagnoses|hosp|d_icd_diagnoses.csv.gz"
  "mimiciv_hosp|d_icd_procedures|hosp|d_icd_procedures.csv.gz"
  "mimiciv_hosp|d_labitems|hosp|d_labitems.csv.gz"
  "mimiciv_hosp|provider|hosp|provider.csv.gz"
  "mimiciv_hosp|patients|hosp|patients.csv.gz"
  "mimiciv_hosp|admissions|hosp|admissions.csv.gz"
  "mimiciv_hosp|drgcodes|hosp|drgcodes.csv.gz"
  "mimiciv_hosp|hcpcsevents|hosp|hcpcsevents.csv.gz"
  "mimiciv_hosp|diagnoses_icd|hosp|diagnoses_icd.csv.gz"
  "mimiciv_hosp|procedures_icd|hosp|procedures_icd.csv.gz"
  "mimiciv_hosp|services|hosp|services.csv.gz"
  "mimiciv_hosp|transfers|hosp|transfers.csv.gz"
  "mimiciv_hosp|microbiologyevents|hosp|microbiologyevents.csv.gz"
  "mimiciv_hosp|omr|hosp|omr.csv.gz"
  "mimiciv_hosp|poe_detail|hosp|poe_detail.csv.gz"
  "mimiciv_icu|caregiver|icu|caregiver.csv.gz"
  "mimiciv_icu|d_items|icu|d_items.csv.gz"
  "mimiciv_icu|icustays|icu|icustays.csv.gz"
  "mimiciv_icu|datetimeevents|icu|datetimeevents.csv.gz"
  "mimiciv_icu|outputevents|icu|outputevents.csv.gz"
  "mimiciv_icu|procedureevents|icu|procedureevents.csv.gz"
  "mimiciv_note|discharge_detail|note|discharge_detail.csv.gz"
  "mimiciv_note|radiology_detail|note|radiology_detail.csv.gz"
)

for row in "${TABLES[@]}"; do
  IFS='|' read -r schema tbl mod fn <<<"$row"
  MARKER="$LOG_DIR/load/${schema}_${tbl}.done"
  LOG="$LOG_DIR/load/${schema}_${tbl}.log"
  if [ -f "$MARKER" ]; then
    echo "[$(date +%H:%M:%S)] SKIP $schema.$tbl (already done)"; continue
  fi
  echo "[$(date +%H:%M:%S)] LOAD $schema.$tbl from $mod/$fn"
  # \copy in psql is implicit single-transaction; ON_ERROR_STOP=1 aborts script on first error
  docker run --rm \
    --network broadsea_default \
    -v "$DATA_DIR:/mimic:ro" \
    -e PGPASSWORD="${ATLASDB_PASS:?ATLASDB_PASS env required}" \
    postgres:16-alpine \
    psql -h broadsea-atlasdb -U postgres -d ohdsi \
         -v ON_ERROR_STOP=1 \
         -c "SET CLIENT_ENCODING TO 'utf8';" \
         -c "TRUNCATE ${schema}.${tbl};" \
         -c "\\copy ${schema}.${tbl} FROM PROGRAM 'gzip -dc /mimic/${mod}/${fn}' DELIMITER ',' CSV HEADER NULL ''" \
    2>&1 | tee "$LOG"
  # record row count
  CNT=$(docker exec broadsea-atlasdb psql -U postgres -d ohdsi -tAc "SELECT count(*) FROM ${schema}.${tbl};")
  echo "[$(date +%H:%M:%S)] ROWS $schema.$tbl = $CNT" | tee -a "$LOG"
  echo "$CNT" > "$MARKER"
done

echo "[$(date +%H:%M:%S)] Stage A complete."
