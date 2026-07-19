# Results

Every experiment run gets a timestamped folder created by `./go snapshot`
(scripts/04-collect-metrics.sh). Committed on purpose: every number in
docs/findings.md must trace back to a raw snapshot here.

Each folder contains:
- `cluster-shape.txt`  node count, pod count, UTC timestamp at snapshot time
- `api_p99_by_verb.json` — apiserver_request_duration p99 per verb (SLO: mutating < 1s)
- `sched_throughput.json` — scheduled pods/sec over the last 5m window
- `sched_e2e_p99.json` — scheduler_pod_scheduling_sli_duration p99
- `sched_pending_pods.json` — queue depth by queue (active/backoff/unschedulable)
- `etcd_p99_by_op.json`, `etcd_db_size_bytes.json`
- `apf_rejected.json`, `apf_queue_wait_p99.json` — API Priority & Fairness pressure
- `watchers_by_kind.json`, `inflight_requests.json`

Reproduce: see the experiment matrix in docs/experiment-design.md; snapshots
must be taken within the 5m rate window after a load phase.
