#!/usr/bin/env bash
# 08-build-pages.sh — build the GitHub Pages site from results/.
# Usage: ./08-build-pages.sh [site-dir]   (default: _site)
#
# Structure produced:
#   _site/index.html        summary tables + links to every run
#   _site/styles.css        shared stylesheet for index.html (scripts/templates/pages-index.css)
#   _site/reports/<run>/    each results/<run>/report.html, copied verbatim
set -euo pipefail
cd "$(dirname "$0")/.."

SITE="${1:-_site}"
TEMPLATE_DIR="scripts/templates"

rm -rf "${SITE}"
mkdir -p "${SITE}/reports"
cp "${TEMPLATE_DIR}/pages-index.css" "${SITE}/styles.css"

# Cache-bust styles.css with a content hash: GitHub Pages serves it at a fixed
# filename across every rebuild, so browsers that already cached an old copy
# keep serving it (this is exactly why the site can look fine in incognito —
# no cache — but stale in a normal browser that visited it before). Appending
# ?v=<hash of the CSS content> changes the URL only when the CSS actually
# changes, forcing a fresh fetch without invalidating the cache on unrelated rebuilds.
CSS_HASH=$(shasum -a 256 "${TEMPLATE_DIR}/pages-index.css" 2>/dev/null | cut -c1-10 || echo "$(date +%s)")

# --- Ensure every snapshot has a rendered report -----------------------------
for dir in results/*/; do
  [ -f "${dir}cluster-shape.txt" ] || continue
  [ -f "${dir}report.html" ] || ./scripts/07-generate-report.sh "${dir}"
done

# --- num <file> <jq-path> -> a bare number, or "—" if missing/NaN -----------
num() {
  local file="$1" path="$2" v
  [ -f "${file}" ] || { echo "—"; return; }
  v="$(jq -r "${path} // empty" "${file}" 2>/dev/null | head -1)"
  [ -z "${v}" ] && echo "—" || echo "${v}"
}

fmt1() { awk -v v="$1" 'BEGIN{ if (v=="—") print "—"; else printf "%.1f", v }'; }
fmt3() { awk -v v="$1" 'BEGIN{ if (v=="—") print "—"; else printf "%.3f", v }'; }
bytes_to_mb() { awk -v b="$1" 'BEGIN{ if (b=="—") print "—"; else printf "%.1f", b/1048576 }'; }

# gpus_for <cluster-shape.txt> <nodes> -> recorded GPU count, or nodes*8 fallback
# for snapshots taken before 04-collect-metrics.sh started recording it.
gpus_for() {
  local shape="$1" nodes="$2" g
  g=$(sed -n 's/^gpus: *//p' "${shape}" 2>/dev/null)
  if [ -z "${g}" ]; then
    awk -v n="${nodes}" 'BEGIN{ if (n ~ /^[0-9]+$/) print n*8; else print "—" }'
  else
    echo "${g}"
  fi
}

# --- Discover snapshot runs, copy their reports, build the summary table ----
run_rows() {
  local dir name nodes gpus pods stamp tput e2e etcd_mb
  for dir in $(ls -d results/*/ 2>/dev/null | sort -r); do
    name="$(basename "${dir}")"
    case "${name}" in cl2-*) continue ;; esac
    [ -f "${dir}report.html" ] || continue

    mkdir -p "${SITE}/reports/${name}"
    cp "${dir}report.html" "${SITE}/reports/${name}/index.html"

    nodes=$(sed -n 's/^nodes: *//p' "${dir}cluster-shape.txt" 2>/dev/null || echo "—")
    gpus=$(gpus_for "${dir}cluster-shape.txt" "${nodes}")
    pods=$(sed -n 's/^pods: *//p' "${dir}cluster-shape.txt" 2>/dev/null || echo "—")
    stamp=$(sed -n 's/^timestamp: *//p' "${dir}cluster-shape.txt" 2>/dev/null || echo "${name}")

    tput=$(fmt1 "$(num "${dir}sched_throughput.json" '.[0].value[1]')")
    e2e=$(fmt3 "$(num "${dir}sched_e2e_p99.json" '.[0].value[1]')")
    etcd_mb=$(bytes_to_mb "$(num "${dir}etcd_db_size_bytes.json" '.[0].value[1]')")

    printf '<tr><td><a href="./reports/%s/">%s</a></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
      "${name}" "${name}" "${stamp}" "${nodes}" "${gpus}" "${pods}" "${tput}" "${e2e}" "${etcd_mb}"
  done
}

# --- Discover ClusterLoader2 runs, build their own summary table -----------
cl2_rows() {
  local dir name st p50 p90 p99 max
  for dir in $(ls -d results/cl2-*/ 2>/dev/null | sort -r); do
    name="$(basename "${dir}")"
    st=$(ls "${dir}"SchedulingThroughput_*.json 2>/dev/null | head -1)
    [ -n "${st}" ] || continue
    p50=$(jq -r '.perc50 // "—"' "${st}" 2>/dev/null)
    p90=$(jq -r '.perc90 // "—"' "${st}" 2>/dev/null)
    p99=$(jq -r '.perc99 // "—"' "${st}" 2>/dev/null)
    max=$(jq -r '.max // "—"' "${st}" 2>/dev/null)
    printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
      "${name}" "${p50}" "${p90}" "${p99}" "${max}"
  done
}

# --- Aggregate stats for the hero KPI row (separate pass — run_rows() runs in
# a subshell via $(...), so variables set inside it wouldn't survive) --------
TOTAL_RUNS=0
MAX_NODES=0
MAX_GPUS=0
MAX_TPUT=0
LATEST_STAMP="—"
FIRST=1
for dir in $(ls -d results/*/ 2>/dev/null | sort -r); do
  name="$(basename "${dir}")"
  case "${name}" in cl2-*) continue ;; esac
  [ -f "${dir}report.html" ] || continue
  TOTAL_RUNS=$((TOTAL_RUNS + 1))
  if [ "${FIRST}" -eq 1 ]; then
    LATEST_STAMP=$(sed -n 's/^timestamp: *//p' "${dir}cluster-shape.txt" 2>/dev/null || echo "${name}")
    FIRST=0
  fi
  nodes=$(sed -n 's/^nodes: *//p' "${dir}cluster-shape.txt" 2>/dev/null || echo 0)
  gpus=$(gpus_for "${dir}cluster-shape.txt" "${nodes}")
  [ "${gpus}" = "—" ] && gpus=0
  tput=$(num "${dir}sched_throughput.json" '.[0].value[1]')
  [ "${tput}" = "—" ] && tput=0
  MAX_NODES=$(awk -v a="${MAX_NODES}" -v b="${nodes}" 'BEGIN{print (b+0>a+0)?b:a}')
  MAX_GPUS=$(awk -v a="${MAX_GPUS}" -v b="${gpus}" 'BEGIN{print (b+0>a+0)?b:a}')
  MAX_TPUT=$(awk -v a="${MAX_TPUT}" -v b="${tput}" 'BEGIN{print (b+0>a+0)?b:a}')
done
MAX_TPUT_FMT=$(fmt1 "${MAX_TPUT}")

RUN_ROWS="$(run_rows)"
CL2_ROWS="$(cl2_rows)"

CL2_SECTION=""
if [ -n "${CL2_ROWS}" ]; then
  CL2_SECTION="<h2>🏁 ClusterLoader2 runs</h2>
<div class=\"table-wrap\">
<table>
<thead><tr><th>Run</th><th>p50</th><th>p90</th><th>p99</th><th>max</th></tr></thead>
<tbody>
${CL2_ROWS}
</tbody>
</table>
</div>
<p class=\"meta\" style=\"margin-top:8px;\">SchedulingThroughput (pods/s), official upstream framework.</p>"
fi

GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "${SITE}/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ghostfleet results</title>
<meta name="description" content="Control-plane scale experiment results for a simulated 1,000-node GPU Kubernetes cluster.">
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>👻</text></svg>">
<link rel="stylesheet" href="styles.css?v=${CSS_HASH}">
</head>
<body>
<div class="wrap">
  <div class="hero">
    <div class="hero-top">
      <div>
        <div class="brand">🏴‍☠️ Ghostfleet</div>
        <h1>Control-plane scale experiment results</h1>
      </div>
      <a class="repo-link" href="https://github.com/hiteshsahu/ghostfleet">View source on GitHub ↗</a>
    </div>
    <p class="meta" style="margin-top:12px;">Auto-generated from <code>results/&lt;timestamp&gt;/</code> snapshots on every push to main.</p>

    <div class="kpi-row">
      <div class="stat-tile"><div class="stat-label">🧪 Runs tracked</div><div class="stat-value">${TOTAL_RUNS}</div></div>
      <div class="stat-tile"><div class="stat-label">🕐 Latest run</div><div class="stat-value" style="font-size:16px;">${LATEST_STAMP}</div></div>
      <div class="stat-tile"><div class="stat-label">🖥️ Largest fleet tested</div><div class="stat-value" style="font-size:20px;">${MAX_NODES}<span class="stat-unit">nodes</span> / ${MAX_GPUS}<span class="stat-unit">GPUs</span></div></div>
      <div class="stat-tile"><div class="stat-label">⚡ Best sched. throughput</div><div class="stat-value">${MAX_TPUT_FMT}<span class="stat-unit">pods/s</span></div></div>
    </div>
  </div>

  <h2>🧪 Experiment runs</h2>
  <div class="table-wrap">
  <table>
    <thead><tr><th>Run</th><th>Timestamp</th><th>🖥️ Nodes</th><th>🎮 GPUs</th><th>📦 Pods</th><th>⚡ Sched. throughput (pods/s)</th><th>⏱️ Sched. e2e p99 (s)</th><th>🗄️ etcd DB (MB)</th></tr></thead>
    <tbody>
${RUN_ROWS}
    </tbody>
  </table>
  </div>

  ${CL2_SECTION}

  <div class="footer">
    <span>Generated ${GENERATED_AT}</span>
    <span><a href="https://kwok.sigs.k8s.io/">KWOK</a> + <a href="https://github.com/kubernetes/perf-tests/tree/master/clusterloader2">ClusterLoader2</a> · results are simulated control-plane load, not real GPU hardware</span>
  </div>
</div>
</body>
</html>
HTML

echo ">> Site built at ${SITE}/"
