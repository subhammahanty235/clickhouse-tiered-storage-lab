#!/usr/bin/env bash
# Fixed query set against both tables. Every cold run drops all three caches
# first; S3 also gets a warm run with caches left intact.
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_up
mkdir -p results
OUT=results/bench_raw.tsv
RUNS="${RUNS:-3}"

# ---- query set -------------------------------------------------------------
q_desc=(
  "Q1 point lookup: one account_id, one month"
  "Q2 narrow aggregate: sum(cost) by service, one month"
  "Q3 wide aggregate: sum(cost) by month across 24 months"
  "Q4 full scan: count() and sum(cost) over everything"
  "Q5 high-cardinality group by: top 20 resource_id by cost, 6 months"
)
q_sql() {
  local t="$2"
  case "$1" in
    Q1) echo "SELECT count(), sum(cost) FROM lab.$t
              WHERE account_id = 'acct-002500'
                AND usage_date >= '2024-06-01' AND usage_date < '2024-07-01'" ;;
    Q2) echo "SELECT service, sum(cost) FROM lab.$t
              WHERE usage_date >= '2024-06-01' AND usage_date < '2024-07-01'
              GROUP BY service ORDER BY service" ;;
    Q3) echo "SELECT toYYYYMM(usage_date) AS m, sum(cost) FROM lab.$t
              GROUP BY m ORDER BY m" ;;
    Q4) echo "SELECT count(), sum(cost) FROM lab.$t" ;;
    Q5) echo "SELECT resource_id, sum(cost) AS c FROM lab.$t
              WHERE usage_date >= '2024-01-01' AND usage_date < '2024-07-01'
              GROUP BY resource_id ORDER BY c DESC LIMIT 20" ;;
  esac
}
QIDS=(Q1 Q2 Q3 Q4 Q5)

drop_caches() {
  chq "SYSTEM DROP FILESYSTEM CACHE"
  chq "SYSTEM DROP MARK CACHE"
  chq "SYSTEM DROP UNCOMPRESSED CACHE"
}

# Run one query under a unique id, then pull its real numbers from query_log.
run_one() {
  local qid="$1" table="$2" mode="$3" run="$4"
  local tag="chs3lab_${qid}_${table}_${mode}_${run}_$$_$(date +%s%N)"
  local sql; sql="$(q_sql "$qid" "$table")"

  [ "$mode" = "cold" ] && drop_caches

  ch --query_id "$tag" --query "$sql
      SETTINGS use_query_cache = 0, enable_filesystem_cache = 1" \
      >/dev/null 2>>results/bench_errors.log || { echo "   ! $qid/$table/$mode failed" >&2; return 1; }

  chq "SYSTEM FLUSH LOGS"
  chq "
    SELECT
      '$qid', '$table', '$mode', $run,
      query_duration_ms,
      read_rows,
      read_bytes,
      ProfileEvents['S3GetObject'],
      ProfileEvents['S3ReadRequestsCount'],
      ProfileEvents['S3ReadBytes'],
      ProfileEvents['CachedReadBufferReadFromSourceBytes'],
      ProfileEvents['CachedReadBufferReadFromCacheBytes']
    FROM system.query_log
    WHERE query_id = '$tag' AND type = 'QueryFinish'
    ORDER BY event_time_microseconds DESC LIMIT 1
    FORMAT TSV" >> "$OUT"
}

# ---- go --------------------------------------------------------------------
: > "$OUT"; : > results/bench_errors.log
printf 'qid\ttable\tmode\trun\tduration_ms\tread_rows\tread_bytes\ts3_get\ts3_read_reqs\ts3_read_bytes\tcache_from_source\tcache_from_cache\n' > "$OUT"

echo "Benchmark: $RUNS runs per query per mode."
echo "Modes: local (baseline) | s3_cold (caches dropped) | s3_warm (caches kept)"
hr

for i in "${!QIDS[@]}"; do
  qid="${QIDS[$i]}"
  echo
  echo "### ${q_desc[$i]}"

  # local baseline -- cold every run, same treatment as s3_cold
  printf '   local   '
  for r in $(seq 1 "$RUNS"); do run_one "$qid" events_local cold "$r" && printf '.'; done; echo

  # s3 cold -- caches dropped before EVERY run
  printf '   s3_cold '
  for r in $(seq 1 "$RUNS"); do run_one "$qid" events_s3 cold "$r" && printf '.'; done; echo

  # s3 warm -- one unrecorded priming run populates the cache, then measure
  printf '   s3_warm '
  run_one "$qid" events_s3 prime 0 >/dev/null 2>&1 || true
  sed -i.bak '/\tprime\t/d' "$OUT" && rm -f "$OUT.bak"
  for r in $(seq 1 "$RUNS"); do run_one "$qid" events_s3 warm "$r" && printf '.'; done; echo
done

hr
echo
echo "=== MEDIAN OF $RUNS RUNS ==="
# Median per (query, table, mode). Keyed on table as well as mode: the local
# baseline also runs with caches dropped, so keying on mode alone would
# collapse it into the s3 cold numbers and lose the baseline.
awk -f "$LAB_DIR/scripts/summarize.awk" "$OUT" | tee results/bench_summary.txt

echo
echo "raw rows: $OUT"
[ -s results/bench_errors.log ] && echo "errors:   results/bench_errors.log"
echo "next: see RESULTS.md"
