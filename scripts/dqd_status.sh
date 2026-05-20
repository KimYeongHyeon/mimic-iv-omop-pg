#!/usr/bin/env bash
# Quick DQD progress check. Usage: ./scripts/dqd_status.sh
#
# Resolves project root relative to this script's location, so it works
# regardless of where the repo is cloned. Override paths with the
# matching env vars if your layout differs.
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LOG="${DQD_DETAIL_LOG:-${PROJECT_ROOT}/output_dqd/log_DqDashboard_MIMIC-IV 2.2.txt}"
RES="${DQD_RESULTS_JSON:-${PROJECT_ROOT}/output_dqd/results.json}"
STDOUT="${DQD_RUNNER_LOG:-${PROJECT_ROOT}/logs/dqd.log}"
ATLASDB_CONTAINER="${ATLASDB_CONTAINER:-broadsea-atlasdb}"
ATLASDB_USER="${ATLASDB_USER:-postgres}"
ATLASDB_DB="${ATLASDB_DB:-ohdsi}"
DQD_CONTAINER="${DQD_CONTAINER:-broadsea-dqd-mimiciv}"

PCT=$(grep -oE '\|[ ]+[0-9]+%' "$STDOUT" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo "?")
PCT_MTIME=$(stat -c '%y' "$STDOUT" 2>/dev/null || echo "?")

echo "=== DQD status @ $(date -Iseconds) ==="
echo "[progress]   ${PCT}% (last update: ${PCT_MTIME})"
if [[ -f "$RES" ]]; then
  echo "[DONE]       results.json present: $(stat -c '%s bytes (mtime: %y)' "$RES")"
else
  echo "[RUNNING]    results.json not yet created"
fi
if [[ -f "$LOG" ]]; then
  echo "[log]        $(stat -c '%s bytes, last write %y' "$LOG")"
  echo "[reconnects] $(grep -c connectPostgreSql "$LOG")"
  echo "[checks]     $(grep -c 'Processing check description' "$LOG") dispatched (target 27)"
fi
echo "[container]  $(docker ps --filter "name=${DQD_CONTAINER}" --format '{{.Status}}')"

echo
echo "=== Active DQD queries ==="
docker exec "$ATLASDB_CONTAINER" psql -U "$ATLASDB_USER" -d "$ATLASDB_DB" -c "
  SELECT pid,
         now() - query_start AS duration,
         state,
         LEFT(regexp_replace(query, E'\\\\s+', ' ', 'g'), 120) AS query
  FROM pg_stat_activity
  WHERE state = 'active'
    AND query LIKE '%num_violated_rows%'
  ORDER BY query_start;
"
