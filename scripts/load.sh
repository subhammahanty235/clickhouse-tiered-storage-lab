#!/usr/bin/env bash
# Generate synthetic cloud-billing rows and load BOTH tables, then force
# merges so parts are large enough to be representative of real S3 usage.
#
# Loads ONE MONTH PER INSERT. A single INSERT spanning all 24 partitions makes
# ClickHouse hold 24 concurrent part-writers (block buffer each, times
# max_threads), which is the dominant memory cost of a bulk load and will trip
# MEMORY_LIMIT_EXCEEDED on a small VM. Month-at-a-time keeps each INSERT inside
# one partition, so peak memory is flat regardless of total row count.
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_up

TOTAL_ROWS="${TOTAL_ROWS:-100000000}"
MONTHS="${MONTHS:-24}"
START_DATE="${START_DATE:-2024-01-01}"
GEN_THREADS="${GEN_THREADS:-4}"
SKIP_SCHEMA="${SKIP_SCHEMA:-0}"
MONTH_START="${MONTH_START:-0}"      # resume: first month index to load
MIN_FREE_GB="${MIN_FREE_GB:-4}"

ROWS_PER_MONTH=$(( TOTAL_ROWS / MONTHS ))

check_disk() {
  local free; free=$(df -g "$LAB_DIR" | tail -1 | awk '{print $4}')
  if [ "$free" -lt "$MIN_FREE_GB" ]; then
    echo; echo "ABORT: only ${free}Gi free (floor ${MIN_FREE_GB}Gi)." >&2
    echo "Free space or lower TOTAL_ROWS, then resume with MONTH_START=<n>." >&2
    exit 1
  fi
}

echo "Loading $TOTAL_ROWS rows = $ROWS_PER_MONTH/month over $MONTHS months."
hr

if [ "$SKIP_SCHEMA" = "1" ]; then
  echo ">> skipping schema (resume mode)"
else
  echo ">> applying schema"
  ch --multiquery < sql/schema.sql
fi

# Deterministic in `number`, so both tables receive byte-identical rows
# without a sort; the checksum at the end proves it.
gen_select() {
  local m="$1" offset="$2" rows="$3"
  cat <<SQL
SELECT
    addMonths(toDate('$START_DATE'), $m)
      + toIntervalDay(number % toUInt32(dateDiff('day',
          addMonths(toDate('$START_DATE'), $m),
          addMonths(toDate('$START_DATE'), $m + 1))))                        AS usage_date,
    concat('acct-', leftPad(toString(cityHash64(number) % 5000), 6, '0'))    AS account_id,
    ['AmazonEC2','AmazonS3','AmazonRDS','AWSLambda','AmazonCloudWatch',
     'AmazonEKS','AmazonRedshift','AWSGlue','AmazonDynamoDB','AmazonVPC'
    ][(cityHash64(number, 1) % 10) + 1]                                      AS service,
    ['us-east-1','us-west-2','eu-west-1','ap-south-1','eu-central-1',
     'ap-southeast-2'][(cityHash64(number, 2) % 6) + 1]                      AS region,
    concat('i-', lower(hex(murmurHash3_128(number))))                        AS resource_id,
    round(abs(sin(number)) * 1000, 4)                                        AS usage_amount,
    round(abs(cos(number)) * 50, 6)                                          AS cost,
    concat('{"env":"', ['prod','dev','stage','qa'][(cityHash64(number,3) % 4) + 1],
           '","team":"team-', toString(cityHash64(number, 4) % 40),
           '","cc":"', toString(cityHash64(number, 5) % 200), '"}')          AS tags
FROM numbers_mt($offset, $rows)
SQL
}

echo ">> loading $MONTHS months into both tables"
m="$MONTH_START"
while [ "$m" -lt "$MONTHS" ]; do
  offset=$(( m * ROWS_PER_MONTH ))
  printf '   month %2d/%d ' "$((m+1))" "$MONTHS"
  start=$(date +%s)
  for t in events_local events_s3; do
    chq "INSERT INTO lab.$t $(gen_select "$m" "$offset" "$ROWS_PER_MONTH")
         SETTINGS max_threads = $GEN_THREADS, max_insert_threads = 1"
  done
  echo "$(( $(date +%s) - start ))s"
  check_disk
  m=$(( m + 1 ))
done

hr
echo ">> parts before merge"
chq "SELECT table, count() AS parts, formatReadableSize(sum(bytes_on_disk)) AS size
     FROM system.parts WHERE database='lab' AND active
     GROUP BY table ORDER BY table FORMAT PrettyCompact"

echo ">> forcing merges (OPTIMIZE FINAL) -- the S3 table rewrites via S3"
for t in events_local events_s3; do
  printf '   %-14s ' "$t"; start=$(date +%s)
  chq "OPTIMIZE TABLE lab.$t FINAL SETTINGS optimize_throw_if_noop = 0"
  echo "$(( $(date +%s) - start ))s"
done

hr
echo ">> verification"
chq "SELECT table, count() AS parts, sum(rows) AS total_rows,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       round(sum(bytes_on_disk) / sum(rows), 2) AS bytes_per_row,
       formatReadableSize(avg(bytes_on_disk)) AS avg_part
     FROM system.parts WHERE database='lab' AND active
     GROUP BY table ORDER BY table FORMAT PrettyCompact"

echo
echo ">> row counts must match"
chq "SELECT (SELECT count() FROM lab.events_local) AS local_rows,
            (SELECT count() FROM lab.events_s3)    AS s3_rows,
            local_rows = s3_rows                   AS match
     FORMAT PrettyCompact"

echo
echo ">> checksum must match (proves identical data, not just identical counts)"
chq "SELECT
       (SELECT sum(cityHash64(usage_date, account_id, service, region,
                              resource_id, usage_amount, cost, tags))
          FROM lab.events_local) AS local_ck,
       (SELECT sum(cityHash64(usage_date, account_id, service, region,
                              resource_id, usage_amount, cost, tags))
          FROM lab.events_s3)    AS s3_ck,
       local_ck = s3_ck          AS match
     FORMAT PrettyCompact
     SETTINGS max_threads = 4"

hr
echo "load complete. next: make verify"
