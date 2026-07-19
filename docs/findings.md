# 📋 Findings

Every number below links to a raw snapshot in [results/](../results/). All runs
are on the same 1,000-node / 8,000-GPU cluster (`./go setup && ./go nodes 1000`,
Podman runtime, 4 CPU / 8GiB VM) — we did not repeat the matrix at 100/500 nodes
as originally scoped in [experiment-design.md](experiment-design.md); instead we
varied workload *shape* at fixed scale (loose vs. tight bin-packing, churn,
standardized CL2 density) since that's where the interesting control-plane
behavior showed up.

| Metric                          | Run A/B — 8,000 pods × 1 GPU ([snapshot](../results/20260719-090923/)) | Run C — 1,000 pods × 8 GPU, tight bin-pack ([snapshot](../results/20260719-090446/)) | Run D — churn 200/s × 600s, mid-run ([snapshot](../results/20260719-102054/)) | Run D — churn 200/s × 600s, post-run ([snapshot](../results/20260719-103101/)) |
|---|---|---|---|---|
| Scheduling throughput (pods/s, 5m avg) | 28.2 | — *(burst too fast for the 5m window)* | 142.8 | 13.5 |
| Scheduling e2e p99 (s) | 0.154 | — | 0.530 | **69.7** |
| API mutating p99 (s) — POST/PUT/PATCH | 0.020 / 0.020 / 0.022 | 0.005 / 0.024 / 0.005 | 0.024 / 0.025 / 0.025 | **60** / 0.30 / 0.76 |
| etcd p99 write (ms) — update/create | 11.5 / 15.7 | 5.0 / 5.0 | 23.7 / 23.4 | **60,000** / 1.4 |
| etcd DB size (MB) | 116.6 | 14.5 | 577.7 | *(query timed out)* |
| Time to schedule full workload | 46s (~173–233 pods/s climbing) | 5s | n/a (sustained load) | n/a |

Official ClusterLoader2 cross-check (Run E, [cl2-20260719-105723](../results/cl2-20260719-105723/),
4,000 pods across 10 namespaces): **SchedulingThroughput p50 188.4 / p90 192.8 /
p99 192.8 / max 192.8 pods/s** — consistent with our own custom-script numbers
above and with the 100–300 pods/s hypothesis in experiment-design.md.

## What broke first

1. **Churn is where this control plane actually breaks — everything else stayed inside SLO.**
   At steady load (Run A/B, Run C) API mutating p99 never exceeded 25ms and
   scheduling e2e p99 stayed under 1s. Under sustained 200 pods/sec churn
   (Run D), API/etcd p99 climbed steadily through the run (~23ms at t=200s)
   and by the end had blown past every upstream SLO by 2–3 orders of
   magnitude: POST p99 and etcd list/update p99 both pinned at **60 seconds**
   (likely a query/measurement ceiling — the true value may be higher), and
   scheduling e2e p99 hit **69.7 seconds** (SLO: <5s).
2. **The churn script doesn't reach steady state — creates outrun deletes.**
   Live pod count in the `churn` namespace grew from 21,546 (t=200s) to
   25,071 (t=~240s) — a net +88 pods/sec even though the target churn rate is
   only ~200/sec *gross* (create+delete combined). `scripts/05-churn.sh`
   backgrounds unbounded `kubectl apply`/`kubectl delete` calls every 2s with
   no concurrency cap and no `--request-timeout`; once the apiserver slows
   even slightly, deletes fall behind creates, live object count grows
   without bound, and the growing object count itself adds more load —
   a feedback loop. This is a confound worth knowing about: Run D as
   currently written measures "control plane vs. an unbounded churn client,"
   not "control plane vs. a rate-limited steady-state churn."
3. **First attempt at Run D OOM-killed the control plane outright.** Before
   the run captured above, an identical `./go churn 200 600` run got
   `kube-apiserver` and Prometheus SIGKILL'd (exit 137) by the OS during the
   run, even on an 8GiB Podman VM, and the cluster did not self-recover —
   `podman ps`/`podman machine list` itself became unresponsive (SSH
   handshake failures to the VM) for over an hour until the Podman machine
   was manually stopped and restarted. The second attempt (captured above)
   survived to completion but only barely, per point 1. Budget real recovery
   time (and a `./go status` health check) after any churn run before trusting
   the cluster for a follow-up experiment.
4. **`kubectl apply` of 1,000 node manifests would crawl under default
   client-side throttling** — avoided by generating one concatenated
   manifest and using server-side apply (`scripts/02-scale-nodes.sh`).
   *Interview story: "first bottleneck at scale is usually the client."*
5. **Upstream ClusterLoader2 no longer ships a `kwok` provider.** Checked
   `pkg/provider/provider.go`'s `NewProvider` switch on a fresh clone of
   `kubernetes/perf-tests` — no `kwok` case exists. `--provider=local` is the
   closest match for a non-cloud cluster. Fixed in `scripts/06-run-cl2.sh`.
6. **CL2's own utility pods can't schedule onto fake GPU nodes.** Both CL2's
   exec-service and its optional managed Prometheus/Grafana Deployments have
   no toleration for our `kwok.x-k8s.io/node=fake:NoSchedule` taint, and there
   are no untainted nodes to fall back to — `0/1000 nodes are available:
   untolerated taint(s)`. Worked around with `--enable-exec-service=false`
   (our test config doesn't need it) and by leaving `--enable-prometheus-server`
   at its default `false` (accept that CL2's own `APIResponsivenessPrometheus`
   measurement no-ops; use `./go snapshot` / `results/*/api_p99_by_verb.json`
   for that data instead — SchedulingThroughput and WaitForRunningPods are
   unaffected and gave the cross-check numbers above).

## What this doesn't tell you
KWOK fakes kubelets and pod lifecycles: no device plugin, no DCGM, no real GPU
allocation, no CNI, no image pulls. These numbers characterize the control
plane under GPU-shaped scheduling load only. The churn numbers additionally
reflect a client-side concurrency bug in `scripts/05-churn.sh` (see "What broke
first" #2) as much as they reflect genuine server-side capacity — treat the
60s figures as "what happens when a churn client doesn't back off," not as a
clean measurement of the control plane's own breaking point.
