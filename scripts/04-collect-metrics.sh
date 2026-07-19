#!/usr/bin/env bash
# 04-collect-metrics.sh — snapshot the SLO-relevant metrics into results/.
# Run right after a workload phase, while the [5m] rate windows still cover it.
set -euo pipefail

PROM="${PROM:-http://127.0.0.1:9090}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DIR="$(dirname "$0")/../results/${STAMP}"
mkdir -p "${DIR}"

q() { # q <name> <promql>
  local NAME="$1"; shift
  echo ">> ${NAME}"
  curl -fsG "${PROM}/api/v1/query" --data-urlencode "query=$*" \
    | jq '.data.result' > "${DIR}/${NAME}.json"
  jq -r '.[] | [(.metric | tostring), .value[1]] | @tsv' "${DIR}/${NAME}.json" | head -20
}

q api_p99_by_verb \
  'histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket{verb!~"WATCH|CONNECT"}[5m])) by (verb, le))'

q sched_throughput \
  'sum(rate(scheduler_schedule_attempts_total{result="scheduled"}[5m]))'

q sched_e2e_p99 \
  'histogram_quantile(0.99, sum(rate(scheduler_pod_scheduling_sli_duration_seconds_bucket[5m])) by (le))'

q sched_pending_pods \
  'sum(scheduler_pending_pods) by (queue)'

q etcd_p99_by_op \
  'histogram_quantile(0.99, sum(rate(etcd_request_duration_seconds_bucket[5m])) by (operation, le))'

q etcd_db_size_bytes \
  'etcd_mvcc_db_total_size_in_bytes'

q apf_rejected \
  'sum(rate(apiserver_flowcontrol_rejected_requests_total[5m])) by (priority_level, reason)'

q apf_queue_wait_p99 \
  'histogram_quantile(0.99, sum(rate(apiserver_flowcontrol_request_wait_duration_seconds_bucket[5m])) by (priority_level, le))'

q watchers_by_kind \
  'sum(apiserver_registered_watchers) by (kind)'

q inflight_requests \
  'sum(apiserver_current_inflight_requests) by (request_kind)'

echo ""
echo ">> Snapshots written to ${DIR}/"
echo ">> Record cluster shape alongside:"
{
  echo "nodes: $(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
  echo "gpus:  $(kubectl get nodes -o json | jq '[.items[].status.allocatable["nvidia.com/gpu"] // "0" | tonumber] | add')"
  echo "pods:  $(kubectl get pods -A --no-headers | wc -l | tr -d ' ')"
  date -u +"timestamp: %Y-%m-%dT%H:%M:%SZ"
} | tee "${DIR}/cluster-shape.txt"
