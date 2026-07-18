# Findings

*(Filled after runs — every number links to a snapshot in results/.)*

| Metric | 100 nodes | 500 nodes | 1,000 nodes |
|---|---|---|---|
| Scheduling throughput (pods/s) | | | |
| Scheduling p99 (s) | | | |
| API mutating p99 (s) | | | |
| etcd p99 write (ms) | | | |
| etcd DB size (MB) | | | |
| Time to schedule full workload | | | |

## What broke first

## What this doesn't tell you
KWOK fakes kubelets and pod lifecycles: no device plugin, no DCGM, no real GPU
allocation, no CNI, no image pulls. These numbers characterize the control
plane under GPU-shaped scheduling load only.
