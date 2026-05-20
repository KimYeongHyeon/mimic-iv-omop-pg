#!/usr/bin/env bash
# Run OHDSI Achilles against mimiciv_cdm using the Broadsea HADES container
# (which has R + Achilles + JDBC drivers pre-installed).
#
# ~1.5-3 hours for 260K patients. Populates mimiciv_cdm_results.achilles_*.
# Required by ATLAS Data Source dashboard (gender pie, year-of-birth histogram,
# top conditions/drugs/measurements panels).
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LOG=${PROJECT_ROOT}/logs/09_achilles.log
NETWORK="${ATLASDB_NETWORK:-broadsea_default}"
HADES_IMAGE="${HADES_IMAGE:-ohdsi/broadsea-hades:1.19.0}"

mkdir -p ${PROJECT_ROOT}/logs

# Make sure the R script is mounted at /scripts inside the container
docker run --rm \
  --network "$NETWORK" \
  --name broadsea-achilles-mimiciv \
  -v ${PROJECT_ROOT}/scripts/run_achilles_mimiciv.R:/scripts/run_achilles.R:ro \
  -e DB_SERVER="${ATLASDB_CONTAINER:-broadsea-atlasdb}/${ATLASDB_DB:-ohdsi}" \
  -e DB_USER="${ATLASDB_USER:-postgres}" \
  -e DB_PASS="${ATLASDB_PASS:-mypass}" \
  -e DB_PORT="${ATLASDB_PORT:-5432}" \
  -e CDM_SCHEMA="${CDM_SCHEMA:-mimiciv_cdm}" \
  -e RESULTS_SCHEMA="${RESULTS_SCHEMA:-mimiciv_cdm_results}" \
  -e SOURCE_NAME="${SOURCE_NAME:-MIMIC-IV 2.2}" \
  "$HADES_IMAGE" \
  Rscript /scripts/run_achilles.R \
  2>&1 | tee "$LOG"

echo "[$(date +%H:%M:%S)] Achilles complete -- see $LOG"
