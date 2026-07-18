# Dashboards

`ghostfleet-slo.json` — Grafana dashboard with the eight SLO views used in
docs/findings.md: API p99 by verb, scheduler throughput, scheduling latency,
pending-pod queues, etcd latency & DB size, API Priority & Fairness pressure,
and watch/inflight load.

kwokctl starts Prometheus (default http://127.0.0.1:9090) but not Grafana.
To use the dashboard:

```bash
docker run -d --name ghostfleet-grafana --network host grafana/grafana-oss
# Grafana at http://127.0.0.1:3000 (admin/admin)
# Add a Prometheus data source pointing at http://127.0.0.1:9090
# Dashboards -> Import -> upload ghostfleet-slo.json, select the data source
```

Screenshots of these panels during runs go to docs/img/ and become the
figures in the write-up.
