#!/usr/bin/env bash
# 06-run-cl2.sh — run ClusterLoader2 (SIG-Scalability's framework) against the
# kwok cluster. This gives you STANDARDIZED, comparable numbers and lets you
# name-drop the exact tool the upstream community uses.
set -euo pipefail

WORKDIR="${WORKDIR:-$HOME/perf-tests}"
CLUSTER_NAME="${CLUSTER_NAME:-ghostfleet}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_DIR="${LAB_DIR}/results/cl2-$(date +%Y%m%d-%H%M%S)"

if [ ! -d "${WORKDIR}" ]; then
  echo ">> Cloning kubernetes/perf-tests..."
  git clone --depth 1 https://github.com/kubernetes/perf-tests "${WORKDIR}"
fi

mkdir -p "${REPORT_DIR}"
cd "${WORKDIR}/clusterloader2"

# --provider=kwok tells CL2 not to expect real kubelets/cloud APIs.
# The density config creates namespaces full of deployments and measures
# scheduling/startup SLIs + API responsiveness.
go run cmd/clusterloader.go \
  --provider=kwok \
  --kubeconfig="${KUBECONFIG_PATH}" \
  --testconfig="${LAB_DIR}/scenarios/density/density-config.yaml" \
  --report-dir="${REPORT_DIR}" \
  --v=2

echo ""
echo ">> CL2 report written to ${REPORT_DIR}"
echo ">> Look for: SchedulingThroughput, PodStartupLatency, APIResponsivenessPrometheus junit/json files."
