#!/usr/bin/env bash
# 05b-churn-limited.sh — rate-limited create/delete churn with bounded concurrency.
# Usage: ./05b-churn-limited.sh 200 600 [max_concurrent] [request_timeout]
#
# Companion to 05-churn.sh, which backgrounds kubectl apply/delete calls every
# 2s with NO concurrency cap and no --request-timeout. Once the apiserver
# slows down even slightly, that lets creates outrun deletes and background
# kubectl processes pile up unbounded — see docs/findings.md "What broke
# first" #2-3, where that pile-up (not the control plane's own limit) drove
# API/etcd p99 to 60s. This version enforces a hard cap on in-flight kubectl
# calls (throttle() blocks new batches until older ones finish) and a
# --request-timeout on every call, so a stuck request eventually gives up
# instead of hanging forever. The result is a real steady-state measurement:
# if the control plane can't keep up, THIS script slows down and says so,
# instead of silently piling up more load on top of an already-struggling
# apiserver.
set -euo pipefail

RATE="${1:-100}"              # target pods created per second (batched)
DURATION="${2:-300}"          # seconds
MAX_CONCURRENT="${3:-6}"      # max in-flight kubectl apply/delete calls
REQ_TIMEOUT="${4:-10s}"       # --request-timeout for every kubectl call
NS="churn"
BATCH_INTERVAL=2
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

# throttle: block until fewer than MAX_CONCURRENT background jobs are in flight.
# This IS the backpressure: if kubectl calls are taking longer than usual
# (server struggling), new batches wait here instead of piling on more load.
THROTTLE_EVENTS=0
throttle() {
  local waited=0
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "${MAX_CONCURRENT}" ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  if [ "${waited}" -gt 0 ]; then
    THROTTLE_EVENTS=$((THROTTLE_EVENTS + 1))
    echo ">> [t=${SECONDS}s] throttled ${waited} x 200ms waiting for in-flight kubectl calls to drain"
  fi
}

echo ">> Rate-limited churn: ~${RATE} pods/s target for ${DURATION}s (batches of ${BATCH} every ${BATCH_INTERVAL}s, max ${MAX_CONCURRENT} concurrent kubectl calls, --request-timeout=${REQ_TIMEOUT})"
END=$((SECONDS + DURATION))
TAG=0
while [ ${SECONDS} -lt ${END} ]; do
  TAG=$((TAG + 1))

  throttle
  gen_batch "${TAG}" | kubectl apply --request-timeout="${REQ_TIMEOUT}" -f - >/dev/null 2>&1 &

  # delete the batch from 3 intervals ago (gives pods a short lifetime)
  if [ ${TAG} -gt 3 ]; then
    throttle
    kubectl delete pods -n "${NS}" -l batch="$((TAG - 3))" --request-timeout="${REQ_TIMEOUT}" --wait=false >/dev/null 2>&1 &
  fi

  sleep "${BATCH_INTERVAL}"
done

echo ">> Batches issued, waiting for in-flight requests to drain..."
wait || true

echo ">> Churn done. ${TAG} batches issued, throttled ${THROTTLE_EVENTS} times (server fell behind target rate that often)."
echo ">> Cleaning up namespace..."
kubectl delete namespace "${NS}" --request-timeout="${REQ_TIMEOUT}" --wait=false
echo ">> Snapshot metrics NOW: ./scripts/04-collect-metrics.sh"
