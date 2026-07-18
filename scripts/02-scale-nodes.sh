#!/usr/bin/env bash
# 02-scale-nodes.sh — create N fake GPU nodes (8x nvidia.com/gpu each).
# Usage: ./02-scale-nodes.sh 1000
#
# We deliberately generate ONE concatenated manifest and apply it server-side.
# Applying 1,000 individual files with default kubectl QPS takes forever —
# that's finding #1 for your write-up (client-side throttling).
set -euo pipefail

COUNT="${1:-100}"
GPUS_PER_NODE="${GPUS_PER_NODE:-8}"
OUT="$(mktemp /tmp/kwok-nodes-XXXXXX)"

echo ">> Generating ${COUNT} fake GPU nodes (${GPUS_PER_NODE} GPUs each) -> ${OUT}"
for i in $(seq 0 $((COUNT - 1))); do
cat >> "${OUT}" <<EOF
---
apiVersion: v1
kind: Node
metadata:
  name: gpu-node-$(printf "%04d" "$i")
  annotations:
    kwok.x-k8s.io/node: fake
    node.alpha.kubernetes.io/ttl: "0"
  labels:
    type: kwok
    kubernetes.io/role: agent
    node.kubernetes.io/instance-type: dgx-sim.8xgpu
    nvidia.com/gpu.present: "true"
    topology.kubernetes.io/zone: zone-$((i % 4))
spec:
  taints:
  - key: kwok.x-k8s.io/node
    value: fake
    effect: NoSchedule
status:
  allocatable:
    cpu: "96"
    memory: 1Ti
    nvidia.com/gpu: "${GPUS_PER_NODE}"
    pods: "256"
  capacity:
    cpu: "96"
    memory: 1Ti
    nvidia.com/gpu: "${GPUS_PER_NODE}"
    pods: "256"
  nodeInfo:
    kubeletVersion: fake
EOF
done

echo ">> Applying (server-side)..."
SECONDS=0
kubectl apply --server-side -f "${OUT}" >/dev/null
echo ">> Applied ${COUNT} nodes in ${SECONDS}s"

echo ">> Waiting for nodes Ready..."
until [ "$(kubectl get nodes -l type=kwok --no-headers 2>/dev/null | grep -c ' Ready')" -ge "${COUNT}" ]; do
  sleep 2
done
echo ">> ${COUNT} fake GPU nodes Ready. Total cluster GPUs: $((COUNT * GPUS_PER_NODE))"
