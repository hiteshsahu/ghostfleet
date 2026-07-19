#!/usr/bin/env bash
# 07-generate-report.sh — render a results/<timestamp>/ snapshot as a self-contained HTML report.
# Usage: ./07-generate-report.sh results/20260719-090923
set -euo pipefail

DIR="${1:?Usage: 07-generate-report.sh <results-dir>}"
[ -d "${DIR}" ] || { echo "No such directory: ${DIR}"; exit 1; }
OUT="${DIR%/}/report.html"

NODES=$(sed -n 's/^nodes: *//p' "${DIR}/cluster-shape.txt" 2>/dev/null || echo "?")
PODS=$(sed -n 's/^pods: *//p' "${DIR}/cluster-shape.txt" 2>/dev/null || echo "?")
STAMP=$(sed -n 's/^timestamp: *//p' "${DIR}/cluster-shape.txt" 2>/dev/null)
[ -z "${STAMP}" ] && STAMP="$(basename "${DIR}")"

# GPUs: read if the snapshot recorded it (scripts/04-collect-metrics.sh writes
# this field going forward); older snapshots predate it, so fall back to the
# project's own 8-GPUs-per-node default (every node manifest so far uses it).
GPUS=$(sed -n 's/^gpus: *//p' "${DIR}/cluster-shape.txt" 2>/dev/null)
if [ -z "${GPUS}" ]; then
  GPUS=$(awk -v n="${NODES}" 'BEGIN{ if (n ~ /^[0-9]+$/) print n*8; else print "—" }')
fi

# scalar <file> <jq-path-to-value> -> prints value or "—"
scalar() {
  local file="${DIR}/$1"
  [ -f "${file}" ] || { echo "—"; return; }
  jq -r "$2" "${file}" 2>/dev/null | head -1 | sed 's/^null$/—/'
}

ETCD_BYTES=$(scalar etcd_db_size_bytes.json '.[0].value[1] // empty')
ETCD_MB=$(awk -v b="${ETCD_BYTES:-}" 'BEGIN{ if (b=="—"||b=="") {print "—"} else {printf "%.1f", b/1048576} }')
SCHED_TPUT=$(scalar sched_throughput.json '.[0].value[1] // empty')
SCHED_TPUT_FMT=$(awk -v v="${SCHED_TPUT:-}" 'BEGIN{ if (v=="—"||v=="") {print "—"} else {printf "%.1f", v} }')
SCHED_E2E=$(scalar sched_e2e_p99.json '.[0].value[1] // empty')
SCHED_E2E_FMT=$(awk -v v="${SCHED_E2E:-}" 'BEGIN{ if (v=="—"||v=="") {print "—"} else {printf "%.3f", v} }')

# bars <file> -> tab-separated "label\tms\tpct" rows, scaled to the file's own max.
# NaN guard: this jq's tonumber happily parses "NaN" into a real NaN float (which
# then fails == null checks silently and poisons max/serializes as "null"), so
# every null-ish check below goes through isnan explicitly instead of == null.
bars() {
  local file="${DIR}/$1"
  [ -f "${file}" ] || return 0
  jq -r '
    [ .[] | {
        label: (.metric.verb // .metric.operation // .metric.queue // .metric.request_kind // .metric.priority_level // "value"),
        sec: (.value[1] | tonumber? // null)
      } | .sec = (if .sec == null or (.sec | isnan) then null else .sec end) ]
    | (map(select(.sec != null)) | (map(.sec) | if length > 0 then max else 0 end)) as $max
    | .[] | [
        .label,
        (if .sec == null then "—" else (.sec * 1000 | tostring) end),
        (if .sec == null then "" elif $max > 0 then (.sec / $max * 100 | tostring) else "0" end)
      ] | @tsv
  ' "${file}" 2>/dev/null
}

# raw_rows <file> -> tab-separated "label\tvalue" rows, no unit conversion (for counts)
raw_rows() {
  local file="${DIR}/$1"
  [ -f "${file}" ] || return 0
  jq -r '.[] | [(.metric.request_kind // .metric.queue // .metric.priority_level // .metric.kind // "value"), .value[1]] | @tsv' "${file}" 2>/dev/null
}

bar_rows_html() {
  local file="$1"
  local rows="" label ms pct ms_fmt width
  while IFS=$'\t' read -r label ms pct; do
    [ -z "${label}" ] && continue
    if [ "${ms}" = "—" ]; then
      ms_fmt="no data"
      width="0"
    else
      ms_fmt=$(awk -v v="${ms}" 'BEGIN{printf "%.2f ms", v}')
      width="${pct}"
    fi
    rows="${rows}
      <div class=\"bar-row\">
        <span class=\"bar-label\">${label}</span>
        <div class=\"bar-track\"><div class=\"bar-fill\" style=\"width:${width}%\"></div></div>
        <span class=\"bar-value\">${ms_fmt}</span>
      </div>"
  done < <(bars "${file}")
  echo "${rows}"
}

table_rows_html() {
  local file="$1"
  local rows="" label ms _pct
  while IFS=$'\t' read -r label ms _pct; do
    [ -z "${label}" ] && continue
    if [ "${ms}" = "—" ]; then
      rows="${rows}<tr><td>${label}</td><td>no data</td></tr>"
    else
      rows="${rows}<tr><td>${label}</td><td>$(awk -v v="${ms}" 'BEGIN{printf "%.2f ms", v}')</td></tr>"
    fi
  done < <(bars "${file}")
  echo "${rows}"
}

# raw_table_rows_html <file> -> table rows for plain counts (no ms conversion)
raw_table_rows_html() {
  local file="$1"
  local rows="" label val
  while IFS=$'\t' read -r label val; do
    [ -z "${label}" ] && continue
    rows="${rows}<tr><td>${label}</td><td>${val}</td></tr>"
  done < <(raw_rows "${file}")
  echo "${rows}"
}

api_bars=$(bar_rows_html api_p99_by_verb.json)
api_table=$(table_rows_html api_p99_by_verb.json)
etcd_bars=$(bar_rows_html etcd_p99_by_op.json)
etcd_table=$(table_rows_html etcd_p99_by_op.json)

apf_rejected_count=$(jq 'length' "${DIR}/apf_rejected.json" 2>/dev/null || echo 0)
apf_wait_count=$(jq 'length' "${DIR}/apf_queue_wait_p99.json" 2>/dev/null || echo 0)
watchers_count=$(jq 'length' "${DIR}/watchers_by_kind.json" 2>/dev/null || echo 0)
watchers_table=$(raw_table_rows_html watchers_by_kind.json)
inflight_table=$(raw_table_rows_html inflight_requests.json)

cat > "${OUT}" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Ghostfleet report — ${STAMP}</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>👻</text></svg>">
<style>
:root {
  color-scheme: light;
  --surface-1:      #fcfcfb;
  --page:           #f9f9f7;
  --text-primary:   #0b0b0b;
  --text-secondary: #52514e;
  --text-muted:     #898781;
  --grid:           #e1e0d9;
  --baseline:       #c3c2b7;
  --series-1:       #2a78d6;
  --good:           #0ca30c;
  --border:         rgba(11,11,11,0.10);
}
@media (prefers-color-scheme: dark) {
  :root:where(:not([data-theme="light"])) {
    color-scheme: dark;
    --surface-1:      #1a1a19;
    --page:           #0d0d0d;
    --text-primary:   #ffffff;
    --text-secondary: #c3c2b7;
    --text-muted:     #898781;
    --grid:           #2c2c2a;
    --baseline:       #383835;
    --series-1:       #3987e5;
    --good:           #0ca30c;
    --border:         rgba(255,255,255,0.10);
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --surface-1:      #1a1a19;
  --page:           #0d0d0d;
  --text-primary:   #ffffff;
  --text-secondary: #c3c2b7;
  --text-muted:     #898781;
  --grid:           #2c2c2a;
  --baseline:       #383835;
  --series-1:       #3987e5;
  --good:           #0ca30c;
  --border:         rgba(255,255,255,0.10);
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  background: var(--page);
  color: var(--text-primary);
}
.viz-root { max-width: 920px; margin: 0 auto; padding: 32px 20px 64px; }
h1 { font-size: 22px; margin: 0 0 4px; }
.subtitle { color: var(--text-secondary); font-size: 14px; margin: 0 0 28px; }
.subtitle code { background: var(--grid); padding: 1px 5px; border-radius: 4px; }
h2 { font-size: 15px; margin: 36px 0 12px; color: var(--text-secondary); font-weight: 600; text-transform: uppercase; letter-spacing: .04em; }
.kpi-row { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; }
.stat-tile { background: var(--surface-1); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; }
.stat-label { font-size: 12px; color: var(--text-secondary); margin-bottom: 6px; }
.stat-value { font-size: 26px; font-weight: 600; }
.stat-unit { font-size: 13px; color: var(--text-muted); margin-left: 4px; }
.card { background: var(--surface-1); border: 1px solid var(--border); border-radius: 10px; padding: 18px 20px; }
.bar-row { display: grid; grid-template-columns: 80px 1fr 90px; align-items: center; gap: 10px; padding: 5px 0; }
.bar-label { font-size: 13px; color: var(--text-secondary); }
.bar-track { height: 16px; background: var(--grid); border-radius: 4px; overflow: hidden; }
.bar-fill { height: 100%; background: var(--series-1); border-radius: 4px; min-width: 2px; }
.bar-value { font-size: 12px; color: var(--text-secondary); text-align: right; font-variant-numeric: tabular-nums; }
details { margin-top: 14px; }
summary { cursor: pointer; font-size: 12px; color: var(--text-secondary); }
table { width: 100%; border-collapse: collapse; margin-top: 8px; font-size: 13px; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--grid); font-variant-numeric: tabular-nums; }
th { color: var(--text-muted); font-weight: 500; }
.status-good { color: var(--good); font-size: 13px; }
.footer { margin-top: 40px; font-size: 12px; color: var(--text-muted); }
</style>
</head>
<body>
<div class="viz-root">
  <h1>👻 Ghostfleet run report</h1>
  <p class="subtitle">🖥️ ${NODES} nodes · 🎮 ${GPUS} GPUs · 📦 ${PODS} pods · snapshot <code>${STAMP}</code></p>

  <h2>📋 Cluster shape</h2>
  <div class="kpi-row">
    <div class="stat-tile"><div class="stat-label">🖥️ Nodes</div><div class="stat-value">${NODES}</div></div>
    <div class="stat-tile"><div class="stat-label">🎮 GPUs</div><div class="stat-value">${GPUS}</div></div>
    <div class="stat-tile"><div class="stat-label">📦 Pods</div><div class="stat-value">${PODS}</div></div>
    <div class="stat-tile"><div class="stat-label">🗄️ etcd DB size</div><div class="stat-value">${ETCD_MB}<span class="stat-unit">MB</span></div></div>
    <div class="stat-tile"><div class="stat-label">⚡ Scheduler throughput</div><div class="stat-value">${SCHED_TPUT_FMT}<span class="stat-unit">pods/s (5m avg)</span></div></div>
    <div class="stat-tile"><div class="stat-label">⏱️ Scheduling e2e p99</div><div class="stat-value">${SCHED_E2E_FMT}<span class="stat-unit">s</span></div></div>
  </div>

  <h2>🌐 API request p99 latency by verb</h2>
  <div class="card">
    ${api_bars:-<p class=\"stat-label\">No data in this snapshot.</p>}
    <details><summary>Table view</summary>
      <table><thead><tr><th>Verb</th><th>p99</th></tr></thead><tbody>${api_table}</tbody></table>
    </details>
    <p class="stat-label" style="margin-top:10px;">SLO: mutating &lt; 1s · read-only namespaced &lt; 5s · read-only cluster-scoped &lt; 30s</p>
  </div>

  <h2>🗄️ etcd request p99 latency by operation</h2>
  <div class="card">
    ${etcd_bars:-<p class=\"stat-label\">No data in this snapshot.</p>}
    <details><summary>Table view</summary>
      <table><thead><tr><th>Operation</th><th>p99</th></tr></thead><tbody>${etcd_table}</tbody></table>
    </details>
  </div>

  <h2>⚖️ Priority &amp; Fairness</h2>
  <div class="card">
    $( [ "${apf_rejected_count}" = "0" ] && [ "${apf_wait_count}" = "0" ] && echo '<p class="status-good">✓ No APF rejections or queue wait observed in this window.</p>' || echo '<p class="stat-label">See raw JSON: apf_rejected.json, apf_queue_wait_p99.json</p>' )
  </div>

  <h2>👀 Watchers &amp; inflight requests</h2>
  <div class="card">
    $( [ "${watchers_count}" = "0" ] && echo '<p class="stat-label">No watcher data in this window.</p>' || echo "<table><thead><tr><th>Kind</th><th>Watchers</th></tr></thead><tbody>${watchers_table}</tbody></table>" )
    <details><summary>Inflight requests</summary>
      <table><thead><tr><th>Kind</th><th>Count</th></tr></thead><tbody>${inflight_table}</tbody></table>
    </details>
  </div>

  <p class="footer">Generated from ${DIR} — raw PromQL snapshots in that folder are the source of truth.</p>
</div>
</body>
</html>
HTML

echo ">> Report written to ${OUT}"
