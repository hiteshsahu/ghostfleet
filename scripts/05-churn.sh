#!/usr/bin/env bash
# 05-churn.sh — sustained create/delete churn to probe APF, etcd, watch load.
# Usage: ./05-churn.sh 200 600   # target ~200 pods/sec of churn for 600s
#
# Mechanism: naked pods (no controller) created in batches, deleted after a
# short TTL. Watch apiserver_flowcontrol_* and etcd metrics while it runs.
set -euo pipefail

RATE="${1:-100}"          # pods created per second (batched)
DURATION="${2:-300}"      # seconds
NS="churn"
BATCH_INTERVAL=2          # seconds between batches
BATCH=$((RATE * BATCH_INTERVAL))

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

SCENARIO="$(dirname "$0")/../scenarios/workloads/churn-pod.yaml"
gen_batch() {
  local TAG="$1"
  for i in $(seq 1 "${BATCH}"); do
    echo "---"
    NAME="churn-${TAG}-${i}" NS="${NS}" TAG="${TAG}" envsubst < "${SCENARIO}"
  done
}

echo ">> Churn: ~${RATE} pods/s for ${DURATION}s (batches of ${BATCH} every ${BATCH_INTERVAL}s)"
END=$((SECONDS + DURATION))
TAG=0
while [ ${SECONDS} -lt ${END} ]; do
  TAG=$((TAG + 1))
  gen_batch "${TAG}" | kubectl apply -f - >/dev/null 2>&1 &
  # delete the batch from 3 intervals ago (gives pods a short lifetime)
  if [ ${TAG} -gt 3 ]; then
    kubectl delete pods -n "${NS}" -l batch="$((TAG - 3))" --wait=false >/dev/null 2>&1 &
  fi
  sleep "${BATCH_INTERVAL}"
done
wait || true
echo ">> Churn done. Cleaning up namespace..."
kubectl delete namespace "${NS}" --wait=false
echo ">> Snapshot metrics NOW: ./scripts/04-collect-metrics.sh"
