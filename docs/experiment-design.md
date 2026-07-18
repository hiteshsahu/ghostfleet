# Ghostfleet — Experiment Design

Committed BEFORE running anything: predictions first, measurements second.

## Hypotheses to test (pick 3–4, write down predictions BEFORE running)

1. **Scheduler throughput**: with default kube-scheduler settings, sustained
   scheduling throughput for pods requesting `nvidia.com/gpu` will be in the
   ~100–300 pods/sec range and will NOT degrade much from 100 → 1,000 nodes
   (filtering scales, scoring is sampled via `percentageOfNodesToScore`).
2. **API latency SLO**: p99 for mutating calls stays < 1s (the upstream SLO)
   until churn (pod creates/deletes per second) crosses some threshold — find it.
3. **Client-side throttling** will be your first bottleneck, not the server:
   default kubectl/client-go QPS (~5–50) chokes long before the API server does.
4. **etcd memory & watch load** grow roughly linearly with object count; a
   burst-delete of 10k pods produces a visible watch-event spike and
   apiserver memory bump.
5. **Priority & Fairness (APF)**: under aggressive load you'll see requests
   queued/rejected in `apiserver_flowcontrol_*` metrics before etcd falls over.

## The Kubernetes scalability SLOs to measure against

- API call latency: 99th percentile per (verb, resource) — mutating < 1s,
  read-only namespaced < 5s, read-only cluster-scoped < 30s.
- Pod startup latency SLO (stateless, no image pull): p99 < 5s. With KWOK,
  "startup" is faked, so measure **scheduling latency** instead:
  `scheduler_pod_scheduling_sli_duration_seconds`.
- Scheduler throughput: pods/sec sustained.

## Experiment matrix

| Run | Nodes | GPUs/node | Workload | What you're probing |
|-----|-------|-----------|----------|---------------------|
| A | 100 | 8 | 2,000 GPU pods (1 GPU each) | baseline throughput + latency |
| B | 500 | 8 | 10,000 GPU pods | scaling trend |
| C | 1000 | 8 | 8,000 pods, 8 GPU each → bin-packing pressure | scheduler under tight fit |
| D | 1000 | 8 | churn: create/delete 200 pods/sec for 10 min | APF, etcd, watch load |
| E | 1000 | 8 | ClusterLoader2 density test | standardized, comparable numbers |

Optional stretch: rerun C with `percentageOfNodesToScore: 100` vs default and
compare throughput — a great one-slide finding.
