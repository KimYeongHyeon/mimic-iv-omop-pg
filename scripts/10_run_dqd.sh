#!/usr/bin/env bash
# Run OHDSI DataQualityDashboard (~3,500 checks) against mimiciv_cdm via HADES.
# Populates RESULTS_SCHEMA.dqdashboard_results plus JSON in output_dqd/.
# Demo (100 patients): ~18 min @ 2 threads.  Full (260K): ~2 h @ 4 threads.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LOG=${PROJECT_ROOT}/logs/10_dqd.log
mkdir -p ${PROJECT_ROOT}/logs ${PROJECT_ROOT}/output_dqd

NETWORK="${ATLASDB_NETWORK:-broadsea_default}"
HADES_IMAGE="${HADES_IMAGE:-ohdsi/broadsea-hades:1.19.0}"

docker run --rm \
  --network "$NETWORK" \
  --name broadsea-dqd-mimiciv \
  -v ${PROJECT_ROOT}/scripts/run_dqd_mimiciv.R:/scripts/run_dqd.R:ro \
  -v ${PROJECT_ROOT}/output_dqd:/output:rw \
  -e DB_SERVER="${ATLASDB_CONTAINER:-broadsea-atlasdb}/${ATLASDB_DB:-ohdsi}" \
  -e DB_USER="${ATLASDB_USER:-postgres}" \
  -e DB_PASS="${ATLASDB_PASS:-mypass}" \
  -e DB_PORT="${ATLASDB_PORT:-5432}" \
  -e CDM_SCHEMA="${CDM_SCHEMA:-mimiciv_cdm}" \
  -e RESULTS_SCHEMA="${RESULTS_SCHEMA:-mimiciv_cdm_results}" \
  -e VOCAB_SCHEMA="${VOCAB_SCHEMA:-mimiciv_cdm}" \
  -e SOURCE_NAME="${SOURCE_NAME:-MIMIC-IV 2.2}" \
  -e DQD_THREADS="${DQD_THREADS:-4}" \
  "$HADES_IMAGE" \
  Rscript /scripts/run_dqd.R \
  2>&1 | tee "$LOG"

echo "[$(date +%H:%M:%S)] DQD complete — see $LOG and output_dqd/results.json"
