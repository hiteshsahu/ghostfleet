# Write-up template: "Scheduling 8,000 GPU pods on my laptop"

Working title options (pick the honest-but-punchy one):
- *I simulated a 1,000-node GPU cluster on my laptop — here's what broke first*
- *Kubernetes at GPU scale, without the GPUs: control-plane experiments with KWOK*

## Structure (thesis-first, your hybrid format)

**Hook / thesis (2–3 sentences):**
The scarce skill in AI infrastructure isn't running GPUs — it's knowing how the
control plane behaves when there are thousands of them. You can practice that
for $0 with KWOK, the simulator SIG-Scalability uses.

**Setup (short):**
- kwokctl cluster: real apiserver/etcd/scheduler, fake nodes
- 1,000 fake DGX-style nodes, 8x `nvidia.com/gpu` each → 8,000 simulated GPUs
- Load: custom GPU workloads + ClusterLoader2 density test
- Measured against upstream SLOs (API p99 <1s mutating, scheduling SLIs)

**Findings (3–5, each: claim → number → why):**
1. [e.g.] First bottleneck was the *client*, not the cluster: ...
2. [e.g.] Scheduler throughput was ~N pods/s at 100 nodes and ~M at 1,000: ...
3. [e.g.] Under 200 pods/s churn, APF started queuing requests at ...
4. [e.g.] Tight bin-packing (8-GPU pods) moved scheduling p99 from X to Y: ...
5. [e.g.] etcd DB grew from A to B MB across the run; watch count peaked at C.

**What this doesn't tell you (mandatory section — your integrity brand):**
KWOK fakes kubelets and pod lifecycles. No device plugin, no DCGM, no real GPU
allocation, no image pulls, no CNI. These numbers characterize the CONTROL
PLANE under GPU-shaped scheduling load — they say nothing about node-level or
data-plane performance. Real clusters hit different walls (image pull storms,
CNI IPAM, kubelet PLEG) that this setup cannot see.

**What I'd test next:**
DRA (Dynamic Resource Allocation) vs device-plugin-style extended resources at
scale; scheduler plugin profiling; comparing percentageOfNodesToScore settings.

## Numbers table (fill from results/)

| Metric | 100 nodes | 500 nodes | 1,000 nodes |
|---|---|---|---|
| Scheduling throughput (pods/s) | | | |
| Scheduling p99 (s) | | | |
| API mutating p99 (s) | | | |
| etcd p99 write (ms) | | | |
| etcd DB size (MB) | | | |
| Time to schedule full workload | | | |

## Rules
- Every number traceable to a snapshot in results/ — link or screenshot Prometheus.
- Say "simulated" in the first paragraph, not the last.
- No hardware-sounding claims (no tokens/sec, no GPU util %) — this is control-plane only.
