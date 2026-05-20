#!/usr/bin/env bash
# Orchestrate the full OHDSI/MIMIC ETL: staging -> etl SQL chain.
# Each script runs in its own transaction (psql script default).
# Idempotency via per-script .done marker.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LOG_DIR=${PROJECT_ROOT}/logs/etl
mkdir -p "$LOG_DIR"
ETL_DIR=${PROJECT_ROOT}/etl

# Stage 1: staging
STAGING=(
  "01_staging/st_core.sql"
  "01_staging/st_hosp.sql"
  "01_staging/st_icu.sql"
  "01_staging/voc_copy_to_target_dataset.sql"
)

# Stage 2: etl (exact order from workflow_etl.conf, minus waveform)
ETL=(
  "02_etl/cdm_location.sql"
  "02_etl/cdm_care_site.sql"
  "02_etl/cdm_person.sql"
  "02_etl/cdm_death.sql"
  "02_etl/lk_vis_part_1.sql"
  "02_etl/lk_meas_unit.sql"
  "02_etl/lk_meas_chartevents.sql"
  "02_etl/lk_meas_labevents.sql"
  "02_etl/lk_meas_specimen.sql"
  "02_etl/lk_meas_outputevents.sql"
  "02_etl/lk_vis_part_2.sql"
  "02_etl/cdm_visit_occurrence.sql"
  "02_etl/cdm_visit_detail.sql"
  "02_etl/lk_cond_diagnoses.sql"
  "02_etl/lk_procedure.sql"
  "02_etl/lk_observation.sql"
  "02_etl/cdm_condition_occurrence.sql"
  "02_etl/cdm_procedure_occurrence.sql"
  "02_etl/cdm_specimen.sql"
  "02_etl/cdm_measurement.sql"
  "02_etl/lk_drug.sql"
  "02_etl/cdm_drug_exposure.sql"
  "02_etl/cdm_device_exposure.sql"
  "02_etl/cdm_observation.sql"
  "02_etl/cdm_observation_period.sql"
  "02_etl/cdm_finalize_person.sql"
  "02_etl/cdm_fact_relationship.sql"
  "02_etl/cdm_condition_era.sql"
  "02_etl/cdm_drug_era.sql"
  "02_etl/cdm_dose_era.sql"
  "02_etl/ext_d_itemid_to_concept.sql"
  "02_etl/cdm_cdm_source.sql"
  "02_etl/cdm_provider.sql"
)

ALL=("${STAGING[@]}" "${ETL[@]}")

for script in "${ALL[@]}"; do
  base=$(basename "$script" .sql)
  marker="$LOG_DIR/${base}.done"
  if [ -f "$marker" ]; then
    echo "[$(date +%H:%M:%S)] SKIP $script (done)"; continue
  fi
  if [ ! -f "$ETL_DIR/$script" ]; then
    echo "[$(date +%H:%M:%S)] MISS $ETL_DIR/$script" | tee -a "$LOG_DIR/missing.log"
    continue
  fi
  echo "[$(date +%H:%M:%S)] RUN  $script"
  START=$(date +%s)
  # SET timeout off for ETL: chartevents CTAS can take 30-60min. PGOPTIONS overrides session.
  if cat "$ETL_DIR/$script" | docker exec -i -e PGOPTIONS="-c statement_timeout=0 -c idle_in_transaction_session_timeout=0" broadsea-atlasdb psql -U postgres -d ohdsi -v ON_ERROR_STOP=1 > "$LOG_DIR/${base}.log" 2>&1; then
    END=$(date +%s); DUR=$((END-START))
    echo "[$(date +%H:%M:%S)] OK   $script  ${DUR}s" | tee -a "$LOG_DIR/_summary.log"
    touch "$marker"
  else
    END=$(date +%s); DUR=$((END-START))
    echo "[$(date +%H:%M:%S)] FAIL $script  ${DUR}s -- see $LOG_DIR/${base}.log" | tee -a "$LOG_DIR/_summary.log"
    echo "--- tail ---"
    tail -20 "$LOG_DIR/${base}.log"
    exit 1
  fi
done

echo "[$(date +%H:%M:%S)] ETL chain complete."
