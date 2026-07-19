# 🧪 Test & Benchmark Results 

#### HTML Results are published on Github Pages: [https://hiteshsahu.github.io/ghostfleet/](https://hiteshsahu.github.io/ghostfleet/)

A github action make sure reports are visble for all test runs when you push results.

### 📸 Snapshots

You can spin off virtually thousands of nodes with virtual GPU and schedule k8 on this nodes. 

The outcome is snapshoted and stored in results to evaluate the boundreies.

Every experiment produces a timestamped snapshot under `results/`.


Snapshots are intentionally committed. Every metric and chart referenced in
`docs/findings.md` can be traced back to its original raw data, making all
experiments reproducible and auditable.

## Snapshot contents

Each snapshot directory contains:

| File | Description |
|------|-------------|
| `cluster-shape.txt` | Node count, pod count, and UTC timestamp |
| `api_p99_by_verb.json` | API server p99 request latency by verb |
| `sched_throughput.json` | Scheduler throughput (pods/sec) |
| `sched_e2e_p99.json` | End-to-end scheduling latency (p99) |
| `sched_pending_pods.json` | Active, backoff, and unschedulable queue depths |
| `etcd_p99_by_op.json` | etcd request latency by operation |
| `etcd_db_size_bytes.json` | etcd database size |
| `apf_rejected.json` | API Priority & Fairness rejected requests |
| `apf_queue_wait_p99.json` | APF queue wait latency (p99) |
| `watchers_by_kind.json` | Registered API watchers grouped by resource |
| `inflight_requests.json` | Current mutating and read request counts |


## Reproducing a snapshot

Run an experiment from `docs/experiment-design.md`, then capture a snapshot
immediately after the load phase while Prometheus still has the previous
5-minute observation window available.

```bash
./go setup
./go nodes 1000
./go load 8000 1
./go snapshot
```

## Design principles

- Raw data is immutable.
- Findings reference snapshot IDs rather than regenerated metrics.
- Every published chart can be reproduced from the corresponding snapshot.
- Conclusions are based on measurements, not observations.