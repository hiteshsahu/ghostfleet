#!/usr/bin/env bash
# go — Ghostfleet task runner.
set -euo pipefail
cd "$(dirname "$0")"

# -----------------------------
# Config
# -----------------------------
CLUSTER_NAME="${CLUSTER_NAME:-ghostfleet}"
PROM_PORT="${PROM_PORT:-9090}"

# -----------------------------
# HELP / HINT (Interactive)
# -----------------------------
help() {
cat <<HEREDOC
Usage: ./go <command> [options]

Commands:
=== 0. 🛠  PREREQUISITES        ===
=== 1. ⚙️  CLUSTER LIFECYCLE    ===
=== 2. 🖥  WORKLOAD              ===
=== 3. 📊 METRICS & TESTING     ===

Enter a number to see details:
HEREDOC

read -rn 1 option
echo ""; echo ""

case ${option} in
  0)
    echo "=== 🛠 PREREQUISITES ==="
    echo "⚙️  check_tools                       -- Verify docker/podman, kubectl, jq, go are installed"
    ;;

  1)
    echo "=== ⚙️ CLUSTER LIFECYCLE ==="
    echo "🏗️  setup                             -- Install kwokctl, create cluster + Prometheus"
    echo "📡  status                            -- Fleet status: control plane, nodes, pods, GPUs"
    echo "🧹  clean                             -- Delete the kwok cluster"
    ;;

  2)
    echo "=== 🖥 WORKLOAD ==="
    echo "🖥️  nodes <N>                         -- Create N fake GPU nodes (8x nvidia.com/gpu each)"
    echo "📦  load <pods> <gpus>                -- Schedule pods requesting GPUs; time it"
    echo "🌊  churn <rate> <sec>                -- Sustained create/delete pressure (APF / etcd / watches)"
    ;;

  3)
    echo "=== 📊 METRICS & TESTING ==="
    echo "📸  snapshot                          -- Dump SLO metrics from Prometheus into results/<timestamp>/"
    echo "📄  report [dir]                      -- Render a results/<timestamp>/ snapshot as HTML (default: latest)"
    echo "🧪  cl2                               -- Run ClusterLoader2 density test"
    ;;

  *)
    echo "Section $option does not exist"
    ;;
esac

echo ""
log "Typical run:  ./go setup && ./go nodes 1000 && ./go load 8000 1 && ./go snapshot"
}

# ---------------------------------------------------------------------------------------
# 0)                  === 🛠 PREREQUISITES ===
# ---------------------------------------------------------------------------------------
function check_tools() {
  log "🛠 Checking required tools..."

  for bin in kubectl jq go; do
    if command -v "$bin" >/dev/null 2>&1; then
      echo "✅ $bin found"
    else
      echo "❌ $bin not found. Please install it."
      exit 1
    fi
  done

  if command -v docker >/dev/null 2>&1; then
    echo "✅ docker found: $(docker --version)"
  elif command -v podman >/dev/null 2>&1; then
    echo "✅ podman found: $(podman --version)"
  else
    echo "❌ Neither docker nor podman found. kwokctl needs one of them."
    exit 1
  fi

  if command -v kwokctl >/dev/null 2>&1; then
    echo "✅ kwokctl found: $(kwokctl --version)"
  else
    echo "⚠️  kwokctl not found yet — ./go setup will install it."
  fi
}

# ---------------------------------------------------------------------------------------
#  1)                === ⚙️ CLUSTER LIFECYCLE ===
# ---------------------------------------------------------------------------------------
function setup() {
  log "🏗️ Creating cluster ${CLUSTER_NAME} + Prometheus on port ${PROM_PORT}..."
  ./scripts/01-setup.sh "$@"
}

function status() {
  log "📡 Fleet status — cluster: ${CLUSTER_NAME}"
  local CTX="kwok-${CLUSTER_NAME}"

  if ! kubectl config get-contexts "${CTX}" >/dev/null 2>&1; then
    echo "❌ No kubeconfig context '${CTX}'. Run ./go setup first."
    return 1
  fi

  echo "🐳 Control plane containers:"
  local RUNTIME=""
  command -v podman >/dev/null 2>&1 && RUNTIME=podman
  [ -z "${RUNTIME}" ] && command -v docker >/dev/null 2>&1 && RUNTIME=docker
  if [ -n "${RUNTIME}" ]; then
    "${RUNTIME}" ps -a --filter "name=kwok-${CLUSTER_NAME}" --format "  {{.Names}}: {{.Status}}" 2>/dev/null
  else
    echo "  ⚠️  no docker/podman found to inspect containers"
  fi

  echo ""
  if ! kubectl --context "${CTX}" get --raw /healthz >/dev/null 2>&1; then
    echo "❌ apiserver unreachable — cluster may be down."
    return 1
  fi
  echo "✅ apiserver reachable"

  echo ""
  echo "🖥️  Nodes:"
  local NODE_COUNT READY_COUNT GPU_CAP
  NODE_COUNT=$(kubectl --context "${CTX}" get nodes -l type=kwok --no-headers 2>/dev/null | wc -l | tr -d ' ')
  READY_COUNT=$(kubectl --context "${CTX}" get nodes -l type=kwok --no-headers 2>/dev/null | { grep -c ' Ready' || true; })
  GPU_CAP=$(kubectl --context "${CTX}" get nodes -l type=kwok -o json 2>/dev/null \
    | jq '[.items[].status.allocatable["nvidia.com/gpu"] // "0" | tonumber] | add')
  echo "  ${READY_COUNT}/${NODE_COUNT} Ready, ${GPU_CAP:-0} GPUs allocatable"

  echo ""
  echo "📦 Pods:"
  local FOUND_NS=0
  for ns in gpu-load churn; do
    if kubectl --context "${CTX}" get ns "${ns}" >/dev/null 2>&1; then
      FOUND_NS=1
      local TOTAL SCHEDULED
      TOTAL=$(kubectl --context "${CTX}" get pods -n "${ns}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
      SCHEDULED=$(kubectl --context "${CTX}" get pods -n "${ns}" --field-selector=spec.nodeName!='' --no-headers 2>/dev/null | wc -l | tr -d ' ')
      echo "  ${ns}: ${SCHEDULED}/${TOTAL} scheduled"
    fi
  done
  [ "${FOUND_NS}" -eq 0 ] && echo "  (no gpu-load/churn namespaces yet — run ./go load or ./go churn)"

  echo ""
  echo "📊 Prometheus: http://127.0.0.1:${PROM_PORT}"
}

function clean() {
  log "🧹 Deleting cluster ${CLUSTER_NAME}..."
  kwokctl delete cluster --name "${CLUSTER_NAME}"
}

# ---------------------------------------------------------------------------------------
#  2)                === 🖥 WORKLOAD ===
# ---------------------------------------------------------------------------------------
function nodes() {
  log "🖥️ Scaling fake GPU nodes..."
  ./scripts/02-scale-nodes.sh "$@"
}

function load() {
  log "📦 Scheduling GPU workload..."
  ./scripts/03-gpu-workload.sh "$@"
}

function churn() {
  log "🌊 Running create/delete churn..."
  ./scripts/05-churn.sh "$@"
}

# ---------------------------------------------------------------------------------------
#  3)                === 📊 METRICS & TESTING ===
# ---------------------------------------------------------------------------------------
function snapshot() {
  log "📸 Collecting metrics snapshot..."
  ./scripts/04-collect-metrics.sh "$@"
}

function cl2() {
  log "🧪 Running ClusterLoader2 density test..."
  ./scripts/06-run-cl2.sh "$@"
}

function report() {
  local dir="${1:-}"
  if [ -z "${dir}" ]; then
    dir=$(ls -td results/*/ 2>/dev/null | head -1)
    [ -z "${dir}" ] && { echo "❌ No results/<timestamp>/ folders found. Run ./go snapshot first."; return 1; }
  fi
  log "📄 Rendering report for ${dir}..."
  ./scripts/07-generate-report.sh "${dir}"
}

# -----------------------------
# Helpers
# -----------------------------
function log() {
  echo -e "\n$1\n"
}

# -----------------------------
# Main
# -----------------------------
subcommand="${1:-}"
case $subcommand in
"" | "-h" | "--help")
  help
  ;;
*)
  shift
  "${subcommand}" "$@"
  ;;
esac
