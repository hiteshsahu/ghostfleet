# I simulated a 1,000-node GPU cluster on my laptop — here's what broke first

## Thesis

The scarce skill in AI infrastructure isn't running GPUs — it's knowing how the
control plane behaves when there are thousands of them. I simulated a
1,000-node, 8,000-GPU Kubernetes cluster on a laptop using KWOK (the tool
SIG-Scalability itself uses to study control-plane scale) and ran it hard
enough to find where it actually breaks. The answer wasn't where I expected,
and it took an OS-level OOM kill to find out.

## Setup

- `kwokctl` cluster: real kube-apiserver, etcd, scheduler, controller-manager —
  fake nodes, fake kubelets, no real GPUs.
- 1,000 fake DGX-style nodes, 8× `nvidia.com/gpu` each → 8,000 simulated GPUs.
- Load: two GPU workload shapes (loose, 1 GPU/pod; tight bin-packing, 8
  GPU/pod), a sustained create/delete churn test, and the official
  ClusterLoader2 density benchmark as a standardized cross-check.
- Measured against upstream Kubernetes scalability SLOs: API mutating p99 <
  1s, scheduling latency p99 < 5s.
- Runtime: Podman, 4 CPU / 8GiB VM, macOS.

## Findings

1. **Steady load never came close to breaking anything.** Scheduling 8,000
   pods at 1 GPU each took 46 seconds; scheduling the same 8,000 GPUs packed 8
   per pod took 5 seconds. API mutating p99 stayed at 20–25ms and scheduling
   e2e p99 at 0.15–0.53s — both comfortably inside SLO the whole time.
   ([snapshot](../results/20260719-090923/), [snapshot](../results/20260719-090446/))

2. **Churn is where it actually broke — and broke badly.** Sustained 200
   pods/sec create/delete churn for 10 minutes pushed API POST p99 and etcd
   list/update p99 to a flat **60 seconds** (a query ceiling — the real
   number may be worse) and scheduling e2e p99 to **69.7 seconds**. That's
   2–3 orders of magnitude past SLOs that held rock-solid under steady load.
   ([snapshot](../results/20260719-103101/))

3. **The first churn attempt didn't degrade gracefully — it OOM-killed the
   control plane outright.** `kube-apiserver` and Prometheus got SIGKILL'd by
   the OS (exit 137) mid-run, even on an 8GiB VM, and the cluster didn't
   self-recover: the Podman VM itself went unresponsive for over an hour and
   needed a manual restart. That's the real "what broke first" story here —
   not a slow API server, a dead one.

4. **The churn script has its own bug, and it's a big part of why things got
   this bad.** Live pod count in the churn namespace grew from 21,546 to
   25,071 in 40 seconds — a net +88 pods/sec, even though the target rate was
   only ~200/sec *gross* (create+delete combined). The churn generator
   backgrounds `kubectl` calls with no concurrency cap, so once the apiserver
   slowed even slightly, deletes fell behind creates and the growing object
   count fed on itself. The 60-second numbers above are as much "what an
   unthrottled client does to a control plane" as they are a clean
   measurement of the server's own limit — an honest caveat, and a lesson in
   its own right: churn-testing your control plane requires a churn
   generator that backs off.

5. **First bottleneck was the client, not the cluster — same old story,
   still true.** `kubectl apply` of 1,000 individual node manifests crawls
   under default client-side throttling; switching to one concatenated
   manifest with server-side apply fixed it immediately.
   *Interview line: "the first bottleneck at scale is usually the client."*

6. **The standardized tool agreed with the custom scripts.** Running the
   same workload shape through the official ClusterLoader2 density benchmark
   — not my own scripts — measured a scheduling throughput of 188–193 pods/s,
   right in line with the ~170–230 pods/s I'd measured independently. Getting
   there required two fixes: upstream ClusterLoader2 has dropped its `kwok`
   provider entirely (`--provider=local` is the closest substitute), and its
   own utility pods (exec-service, managed Prometheus) can't schedule onto
   nodes carrying a custom `NoSchedule` taint — which is exactly the taint
   this project uses to keep "real" workloads off the fake GPU nodes.
   ([cl2 report](../results/cl2-20260719-105723/))

## What this doesn't tell you

KWOK fakes kubelets and pod lifecycles: no device plugin, no DCGM, no real
GPU allocation, no CNI, no image pulls. These numbers characterize the
**control plane** under GPU-shaped scheduling load — they say nothing about
node-level or data-plane performance. Real clusters hit different walls
(image pull storms, CNI IPAM, kubelet PLEG) that this setup cannot see. And
the churn numbers specifically are confounded by the churn script's own lack
of backpressure (finding 4) — treat them as "what happens when a client
doesn't back off," not a clean ceiling on the control plane itself.

## What I'd test next

- Fix the churn script to actually rate-limit (bounded concurrency, real
  steady state) and re-run to get a cleaner server-side breaking point.
- Compare `percentageOfNodesToScore: 100` vs. default under tight
  bin-packing — a one-slide finding waiting to happen.
- DRA (Dynamic Resource Allocation) vs. device-plugin-style extended
  resources at scale.
- Add an untainted "system" node pool so ClusterLoader2's own Prometheus can
  run in-cluster, to get official `APIResponsivenessPrometheus` numbers
  alongside the ones gathered independently here.

## Numbers

We didn't repeat this matrix at 100/500 nodes as originally scoped — every
run below is on the same 1,000-node / 8,000-GPU cluster, varying workload
*shape* instead, since that's where the interesting behavior showed up.

| Metric | Steady, 1 GPU/pod | Steady, 8 GPU/pod (tight) | Churn, mid-run | Churn, post-run |
|---|---|---|---|---|
| Scheduling throughput (pods/s, 5m avg) | 28.2 | — | 142.8 | 13.5 |
| Scheduling e2e p99 (s) | 0.154 | — | 0.530 | **69.7** |
| API mutating p99 (s) | 0.020 | 0.005–0.024 | 0.024–0.025 | **60** |
| etcd p99 write (ms) | 11.5–15.7 | 5.0 | 23.4–23.7 | **60,000** |
| etcd DB size (MB) | 116.6 | 14.5 | 550.9 | *(query timed out)* |
| Time to schedule full workload | 46s | 5s | n/a | n/a |

Official ClusterLoader2 cross-check: SchedulingThroughput p50 188.4 / p90 /
p99 / max 192.8 pods/s.

Every number here links to a raw Prometheus snapshot in
[results/](../results/); the full run-by-run breakdown (plus two more
"what broke" items about the ClusterLoader2 provider/taint issues) is in
[findings.md](findings.md).
