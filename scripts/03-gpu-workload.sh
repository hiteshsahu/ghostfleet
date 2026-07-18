#!/usr/bin/env bash
# 03-gpu-workload.sh — schedule N pods requesting G GPUs each; time it.
# Usage: ./03-gpu-workload.sh 8000 1     # 8,000 pods, 1 GPU each
#        ./03-gpu-workload.sh 1000 8     # 1,000 pods, 8 GPUs each (bin-packing)
#
# Uses a Deployment so you also observe controller-manager behavior. The pods
# tolerate the kwok taint and request nvidia.com/gpu, so ONLY the fake GPU
# nodes are feasible — the scheduler must do real extended-resource accounting.
set -euo pipefail

REPLICAS="${1:-2000}"
GPUS_PER_POD="${2:-1}"
NS="gpu-load"

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

SCENARIO="$(dirname "$0")/../scenarios/workloads/training-job.yaml"
export NS REPLICAS GPUS_PER_POD
envsubst < "${SCENARIO}" | kubectl apply -f - >/dev/null

echo ">> Deployment applied: ${REPLICAS} pods x ${GPUS_PER_POD} GPU(s). Timing until all scheduled..."
SECONDS=0
LAST=0
while true; do
  SCHEDULED=$(kubectl get pods -n "${NS}" --field-selector=spec.nodeName!='' --no-headers 2>/dev/null | wc -l | tr -d ' ')
  RATE=$(( (SCHEDULED - LAST) / 5 ))
  echo "t=${SECONDS}s scheduled=${SCHEDULED}/${REPLICAS} (~${RATE} pods/s)"
  LAST=${SCHEDULED}
  [ "${SCHEDULED}" -ge "${REPLICAS}" ] && break
  sleep 5
done
echo ""
echo ">> RESULT: ${REPLICAS} pods (${GPUS_PER_POD} GPU each) scheduled in ${SECONDS}s"
echo ">> Coarse avg throughput: $(( REPLICAS / (SECONDS>0 ? SECONDS : 1) )) pods/s"
echo ">> Now pull exact numbers from Prometheus: ./scripts/04-collect-metrics.sh"
echo ">> GPU utilization view (allocated vs capacity):"
TOTAL_ALLOC=$((REPLICAS * GPUS_PER_POD))
TOTAL_CAP=$(kubectl get nodes -l type=kwok -o json | jq '[.items[].status.allocatable["nvidia.com/gpu"] | tonumber] | add')
echo "   ${TOTAL_ALLOC} / ${TOTAL_CAP} GPUs allocated"
