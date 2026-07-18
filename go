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
