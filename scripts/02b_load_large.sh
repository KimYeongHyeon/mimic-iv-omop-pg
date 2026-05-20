#!/usr/bin/env bash
# Stage B: load large MIMIC-IV tables (>= 100 MB compressed).
# Sorted small-to-large to fail-fast and produce incremental progress.
# Each \copy is its own transaction; ON_ERROR_STOP=1 aborts on first error.
# Idempotent via per-table .done markers in logs/load/.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DATA_DIR=${PROJECT_ROOT}/data/MIMIC-IV-2.2
LOG_DIR=${PROJECT_ROOT}/logs
mkdir -p "$LOG_DIR/load"

# Ordered small -> large by compressed size
TABLES=(
  "mimiciv_icu|ingredientevents|icu|ingredientevents.csv.gz"        # 240 MB
  "mimiciv_icu|inputevents|icu|inputevents.csv.gz"                  # 309 MB
  "mimiciv_hosp|pharmacy|hosp|pharmacy.csv.gz"                      # 380 MB
  "mimiciv_hosp|prescriptions|hosp|prescriptions.csv.gz"            # 437 MB
  "mimiciv_hosp|emar_detail|hosp|emar_detail.csv.gz"                # 449 MB
  "mimiciv_hosp|poe|hosp|poe.csv.gz"                                # 475 MB
  "mimiciv_hosp|emar|hosp|emar.csv.gz"                              # 485 MB
  "mimiciv_note|radiology|note|radiology.csv.gz"                    # 745 MB (text)
  "mimiciv_note|discharge|note|discharge.csv.gz"                    # 1086 MB (text)
  "mimiciv_hosp|labevents|hosp|labevents.csv.gz"                    # 1849 MB
  "mimiciv_icu|chartevents|icu|chartevents.csv.gz"                  # 2353 MB
)

for row in "${TABLES[@]}"; do
  IFS='|' read -r schema tbl mod fn <<<"$row"
  MARKER="$LOG_DIR/load/${schema}_${tbl}.done"
  LOG="$LOG_DIR/load/${schema}_${tbl}.log"
  if [ -f "$MARKER" ]; then
    echo "[$(date +%H:%M:%S)] SKIP $schema.$tbl (already done, rows=$(cat $MARKER))"; continue
  fi
  echo "[$(date +%H:%M:%S)] BEGIN $schema.$tbl from $mod/$fn"
  START=$(date +%s)

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

  CNT=$(docker exec broadsea-atlasdb psql -U postgres -d ohdsi -tAc "SELECT count(*) FROM ${schema}.${tbl};")
  END=$(date +%s); DUR=$((END-START))
  echo "[$(date +%H:%M:%S)] DONE $schema.$tbl rows=$CNT secs=$DUR" | tee -a "$LOG"
  echo "$CNT" > "$MARKER"
done

echo "[$(date +%H:%M:%S)] Stage B complete."
