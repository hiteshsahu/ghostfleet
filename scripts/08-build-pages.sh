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

# --- Discover snapshot runs, copy their reports, build the summary table ----
run_rows() {
  local dir name nodes pods stamp tput e2e etcd_mb
  for dir in $(ls -d results/*/ 2>/dev/null | sort -r); do
    name="$(basename "${dir}")"
    case "${name}" in cl2-*) continue ;; esac
    [ -f "${dir}report.html" ] || continue

    mkdir -p "${SITE}/reports/${name}"
    cp "${dir}report.html" "${SITE}/reports/${name}/index.html"

    nodes=$(sed -n 's/^nodes: *//p' "${dir}cluster-shape.txt" 2>/dev/null || echo "—")
    pods=$(sed -n 's/^pods: *//p' "${dir}cluster-shape.txt" 2>/dev/null || echo "—")
    stamp=$(sed -n 's/^timestamp: *//p' "${dir}cluster-shape.txt" 2>/dev/null || echo "${name}")

    tput=$(fmt1 "$(num "${dir}sched_throughput.json" '.[0].value[1]')")
    e2e=$(fmt3 "$(num "${dir}sched_e2e_p99.json" '.[0].value[1]')")
    etcd_mb=$(bytes_to_mb "$(num "${dir}etcd_db_size_bytes.json" '.[0].value[1]')")

    printf '<tr><td><a href="./reports/%s/">%s</a></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
      "${name}" "${stamp}" "${nodes}" "${pods}" "${tput}" "${e2e}" "${etcd_mb}"
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

RUN_ROWS="$(run_rows)"
CL2_ROWS="$(cl2_rows)"

CL2_SECTION=""
if [ -n "${CL2_ROWS}" ]; then
  CL2_SECTION="<h2>ClusterLoader2 runs</h2>
<table>
<thead><tr><th>Run</th><th>p50</th><th>p90</th><th>p99</th><th>max</th></tr></thead>
<tbody>
${CL2_ROWS}
</tbody>
</table>
<p class=\"meta\">SchedulingThroughput (pods/s), official upstream framework.</p>"
fi

cat > "${SITE}/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Ghostfleet results</title>
<link rel="stylesheet" href="styles.css">
</head>
<body>
<div class="wrap">
  <h1>Ghostfleet — run reports</h1>
  <p class="meta">Auto-generated from results/&lt;timestamp&gt;/ snapshots on every push to main.</p>

  <h2>Experiment runs</h2>
  <table>
    <thead><tr><th>Run</th><th>Timestamp</th><th>Nodes</th><th>Pods</th><th>Sched. throughput (pods/s)</th><th>Sched. e2e p99 (s)</th><th>etcd DB (MB)</th></tr></thead>
    <tbody>
${RUN_ROWS}
    </tbody>
  </table>

  ${CL2_SECTION}
</div>
</body>
</html>
HTML

echo ">> Site built at ${SITE}/"
