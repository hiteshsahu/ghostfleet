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

# --provider=kwok does not exist upstream (checked pkg/provider/provider.go's
# NewProvider switch — no kwok case). --provider=local is the closest match
# for a non-cloud cluster with no real kubelets/cloud APIs.
#
# --enable-exec-service=false: CL2's own exec-service utility pods have no
# toleration for our fake-node taint (kwok.x-k8s.io/node=fake:NoSchedule), so
# with it left on they sit forever at "0 running / not scheduled" — every one
# of our 1,000 nodes rejects them and there are no untainted nodes to fall
# back to. Our test config doesn't use any exec-based measurement, so it's
# safe to disable outright.
#
# --enable-prometheus-server=false (the default): setting it true makes CL2
# deploy its own managed prometheus-operator + Grafana into the cluster, but
# those Deployments hit the exact same wall as exec-service above — they
# don't tolerate our fake-node taint either, so they sit Pending forever
# ("0/1000 nodes are available: untolerated taint(s)") and the run never
# proceeds. Left disabled, APIResponsivenessPrometheus silently no-ops
# ("Prometheus is disabled, skipping the measurement!") — SchedulingThroughput
# and WaitForRunningPods are unaffected. For API-latency numbers, use the ones
# already captured via kwokctl's own Prometheus: ./go snapshot / results/*/api_p99_by_verb.json.
go run cmd/clusterloader.go \
  --provider=local \
  --enable-exec-service=false \
  --kubeconfig="${KUBECONFIG_PATH}" \
  --testconfig="${LAB_DIR}/scenarios/density/density-config.yaml" \
  --report-dir="${REPORT_DIR}" \
  --v=2

echo ""
echo ">> CL2 report written to ${REPORT_DIR}"
echo ">> Look for: SchedulingThroughput, PodStartupLatency, APIResponsivenessPrometheus junit/json files."
