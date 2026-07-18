#!/usr/bin/env bash
# 01-setup.sh — install kwok/kwokctl and create a cluster with metrics enabled.
# Prereqs: Docker running, kubectl installed.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ghostfleet}"
PROM_PORT="${PROM_PORT:-9090}"

# --- Install kwok + kwokctl (latest release) -------------------------------
if ! command -v kwokctl >/dev/null 2>&1; then
  echo ">> Installing kwok + kwokctl..."
  KWOK_REPO="kubernetes-sigs/kwok"
  KWOK_VERSION="$(curl -fsSL "https://api.github.com/repos/${KWOK_REPO}/releases/latest" | jq -r '.tag_name')"
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && ARCH=amd64; [ "$ARCH" = "aarch64" ] && ARCH=arm64
  for BIN in kwok kwokctl; do
    curl -fsSL -o "/tmp/${BIN}" \
      "https://github.com/${KWOK_REPO}/releases/download/${KWOK_VERSION}/${BIN}-${OS}-${ARCH}"
    chmod +x "/tmp/${BIN}"
    sudo mv "/tmp/${BIN}" /usr/local/bin/"${BIN}"
  done
  echo ">> Installed kwok ${KWOK_VERSION}"
else
  echo ">> kwokctl already installed: $(kwokctl --version || true)"
fi

# --- Create cluster ---------------------------------------------------------
# Notes:
#  * --runtime podman: control plane components run as containers.
#  * --prometheus-port: kwokctl deploys Prometheus pre-wired to scrape
#    apiserver / scheduler / controller-manager / etcd / kwok-controller.
#  * We raise controller-manager and scheduler client QPS so THEY are not the
#    bottleneck when we want to probe the API server (comment out to study
#    default behavior — that contrast is experiment-worthy in itself).
#  * kwokctl has no --kube-*-extra-args flags; the real flag is a single
#    repeatable --extra-args component=key=value. Passing it twice for the
#    SAME component panics on kwokctl v0.8.0 ("index out of range"), so we
#    set only kube-api-qps per component (skip kube-api-burst) as a workaround.
echo ">> Creating cluster ${CLUSTER_NAME}..."
kwokctl create cluster \
  --name "${CLUSTER_NAME}" \
  --runtime podman \
  --prometheus-port "${PROM_PORT}" \
  --extra-args kube-controller-manager=kube-api-qps=200 \
  --extra-args kube-scheduler=kube-api-qps=200

kubectl config use-context "kwok-${CLUSTER_NAME}"
kubectl cluster-info

echo ""
echo ">> Done. Prometheus: http://127.0.0.1:${PROM_PORT}"
echo ">> Next: ./scripts/02-scale-nodes.sh 1000"
