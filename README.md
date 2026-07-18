# Ghost Fleet 🏴‍☠️

> A 1,000-node GPU cluster with nobody aboard.
> 
> ![](./docs/img/cover.png)

GhostFleet simulates a 1,000-node / 8,000-GPU Kubernetes cluster on a laptop using
KWOK and ClusterLoader2 to study control-plane scalability.

Control-plane scale experiments against a simulated GPU cluster, using 
- [KWOK](https://kwok.sigs.k8s.io/) 
- [ClusterLoader2](https://github.com/kubernetes/perf-tests/tree/master/clusterloader2). 

Hypotheses in [docs/experiment-design.md](docs/experiment-design.md), numbers in [docs/findings.md](docs/findings.md), raw data in [results/](results/).
Simulate a 1,000-node / 8,000-GPU Kubernetes cluster on a laptop, load it with
ClusterLoader2 and a custom GPU scheduling workload, and measure how the control
plane behaves — API latency, scheduler throughput, etcd pressure.

**Why simulate?** The scarce skill in AI infrastructure isn't running GPUs —
it's knowing how the control plane behaves when there are thousands of them.
KWOK is the simulator SIG-Scalability itself uses to study control-plane scale
without hardware; this repo uses it to run honest, reproducible experiments
against the upstream scalability SLOs.

---

## What KWOK does and does not simulate

KWOK runs a **real** kube-apiserver, etcd, scheduler, and controller-manager
(via `kwokctl`, using Docker or Podman). The *nodes* and *pod lifecycles* are faked by the
kwok controller: nodes heartbeat, pods go Pending → Running instantly, but no
kubelet, no containers, no real GPUs.

- ✅ Exercised for real: API server, etcd, scheduler, controllers, watches,
  admission, resource accounting (including extended resources like
  `nvidia.com/gpu`), taints/tolerations, affinity, topology spread.
- ❌ Not exercised: kubelet, CNI/CSI, device plugin gRPC, DCGM, actual GPU
  allocation. Knowing the boundary of the
  simulation is the point — these experiments characterize the control plane
  only, and every claim in [docs/findings.md](docs/findings.md) is scoped accordingly.




## Quickstart

### Prereqs
Docker or Podman running, kubectl, jq, go (for CL2). 8GB+ RAM free.


### Go CLI 

Start by cloning the repo and running the `go` script in the root directory. It wraps the commands below, but you can also run them directly.

```bash
# Bootstrap GhostFleet
./go setup                 # Install dependencies and create the KWOK cluster + Prometheus
./go check_tools           # verifies the tool are installed

```

Start the fleet, load it with pods, and snapshot the metrics.

```bash
# Build the fleet
./go nodes 1000            # creates 1,000 fake GPU nodes (8x nvidia.com/gpu each)

# Fire the cannons
./go load 8000 1           # schedules 8,000 pods requesting 1 GPU; times it

# Collect the treasure
./go snapshot              # snapshots key PromQL results into results

# Stir the seas
./go churn 200 600         # Generate 200 pods/sec churn for 600s(10 minutes) :: experiment D
```

Benchmark the control plane with ClusterLoader2, which runs the official Kubernetes density benchmark.

```bash
# Official Kubernetes benchmark
./go cl2                   # Run the ClusterLoader2 density benchmark :: experiment E

# Scuttle the fleet
./go clean                 # Delete the cluster and clean up

```

Prometheus UI: http://127.0.0.1:9090 (started by kwokctl).

### Key metrics / PromQL cheat sheet

```bash
# API p99 latency by verb (the SLO chart)
histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket{verb!~"WATCH|CONNECT"}[1m])) by (verb, le))

# Scheduler throughput (pods scheduled per second)
sum(rate(scheduler_schedule_attempts_total{result="scheduled"}[1m]))

# End-to-end scheduling latency p99
histogram_quantile(0.99, sum(rate(scheduler_pod_scheduling_sli_duration_seconds_bucket[5m])) by (le))

# etcd request latency + DB size
histogram_quantile(0.99, sum(rate(etcd_request_duration_seconds_bucket[1m])) by (operation, le))
etcd_mvcc_db_total_size_in_bytes

# Priority & Fairness: are requests queuing/rejected?
sum(rate(apiserver_flowcontrol_dispatched_requests_total[1m])) by (priority_level)
sum(rate(apiserver_flowcontrol_rejected_requests_total[1m])) by (priority_level, reason)
histogram_quantile(0.99, sum(rate(apiserver_flowcontrol_request_wait_duration_seconds_bucket[1m])) by (priority_level, le))

# Watch pressure
sum(apiserver_registered_watchers) by (kind)

# Inflight requests vs limits
sum(apiserver_current_inflight_requests) by (request_kind)
```

---

## What will probably break 

1. `kubectl apply` of 1,000 node manifests crawls → client-side throttling.
   Fix: single concatenated manifest + server-side apply, or raise client QPS.
   *Interview story: "first bottleneck at scale is usually the client."*
2. Creating 8,000 pods via one Deployment: controller-manager's own client QPS
   (`--kube-api-qps`, default 20) rate-limits pod creation — the scheduler ends
   up starved, not slow. Distinguish "scheduler is slow" from "scheduler is
   underfed" using `scheduler_pending_pods` vs attempt rate.
3. Prometheus itself becomes a load source at high churn (watch + scrape).
4. At tight bin-packing (run C), watch scheduling latency p99 climb as feasible
   nodes become scarce — filtering does more work per pod.


---


## Repository layout

```
    .
    │
    ├── scenarios/          # ClusterLoader2 configs and workload definitions
    │   ├── density/
    │   └── workloads/
    │
    ├── manifests/          # Fake GPU node templates and Kubernetes manifests
    │
    ├── dashboards/         # Grafana dashboards
    │
    ├── scripts/            # Helper scripts (optional)
    │
    ├── results/            # Raw benchmark results (gitignored)
    │
    ├── docs/
    │   ├── experiment-design.md
    │   ├── findings.md
    │   ├── writeup-template.md
    │   └── architecture.md
    │
    ├── go
    ├── README.md
    └── LICENSE
```
