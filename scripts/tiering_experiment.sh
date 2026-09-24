#!/usr/bin/env bash
# Per-phase DiskS3 request accounting for an EBS -> S3 tiered table.
#
# Counters in system.events are cumulative since server start, so every phase
# is recorded as a snapshot and reported as a DELTA. The server must not be
# restarted mid-run or the counters reset.
#
# Phases:
#   00 baseline      fresh server, table created, nothing loaded
#   01 after_load    rows written; all land on the HOT volume (expect ~0 S3)
#   02 after_ttl     TTL applied and moves settled: one-time migration cost
#   03 idle_soak     no queries, no inserts: pure background churn on cold data
#   04 after_bench   read cost of querying across both tiers
#   05 late_insert   a row dated past the TTL, i.e. arriving straight into cold
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_up

SOAK_MINUTES="${SOAK_MINUTES:-45}"
TOTAL_ROWS="${TOTAL_ROWS:-1000000}"
MONTHS=24
# Data must END near today so a 12-month TTL leaves half hot, half cold.
START_DATE="${START_DATE:-$(date -v-23m +%Y-%m-01 2>/dev/null || date -d '23 months ago' +%Y-%m-01)}"
TTL_MONTHS="${TTL_MONTHS:-12}"
ROWS_PER_MONTH=$(( TOTAL_ROWS / MONTHS ))

snap() { "$LAB_DIR/scripts/s3_counters.sh" snap "$1" >/dev/null; echo "   [snapshot: $1]"; }

echo "Tiering request-cost experiment"
echo "  rows       : $TOTAL_ROWS over $MONTHS months from $START_DATE"
echo "  TTL        : $TTL_MONTHS months -> VOLUME 'cold'"
echo "  idle soak  : $SOAK_MINUTES min"
echo "  uptime     : $(chq 'SELECT uptime()')s (counters are since server start)"
hr

# ---------------------------------------------------------------- phase 00
echo ">> phase 00: baseline (table created, empty)"
chq "DROP TABLE IF EXISTS lab.events_tiered SYNC"
chq "CREATE TABLE lab.events_tiered
     (usage_date Date, account_id String, service LowCardinality(String),
      region LowCardinality(String), resource_id String,
      usage_amount Float64, cost Float64, tags String)
     ENGINE = MergeTree
     PARTITION BY toYYYYMM(usage_date)
     ORDER BY (account_id, service, usage_date)
     SETTINGS storage_policy = 'tiered',
              old_parts_lifetime = 30,
              merge_with_ttl_timeout = 60"
snap 00_baseline

# ---------------------------------------------------------------- phase 01
echo ">> phase 01: load $TOTAL_ROWS rows (should land entirely on HOT)"
m=0
while [ "$m" -lt "$MONTHS" ]; do
  offset=$(( m * ROWS_PER_MONTH ))
  chq "INSERT INTO lab.events_tiered
  SELECT
    addMonths(toDate('$START_DATE'), $m)
      + toIntervalDay(number % toUInt32(dateDiff('day',
          addMonths(toDate('$START_DATE'), $m),
          addMonths(toDate('$START_DATE'), $m + 1))))                       AS usage_date,
    concat('acct-', leftPad(toString(cityHash64(number) % 5000), 6, '0'))   AS account_id,
    ['AmazonEC2','AmazonS3','AmazonRDS','AWSLambda','AmazonCloudWatch',
     'AmazonEKS','AmazonRedshift','AWSGlue','AmazonDynamoDB','AmazonVPC'
    ][(cityHash64(number, 1) % 10) + 1]                                     AS service,
    ['us-east-1','us-west-2','eu-west-1','ap-south-1','eu-central-1',
     'ap-southeast-2'][(cityHash64(number, 2) % 6) + 1]                     AS region,
    concat('i-', lower(hex(murmurHash3_128(number))))                       AS resource_id,
    round(abs(sin(number)) * 1000, 4)                                       AS usage_amount,
    round(abs(cos(number)) * 50, 6)                                         AS cost,
    concat('{\"env\":\"', ['prod','dev','stage','qa'][(cityHash64(number,3) % 4) + 1],
           '\",\"team\":\"team-', toString(cityHash64(number, 4) % 40), '\"}') AS tags
  FROM numbers_mt($offset, $ROWS_PER_MONTH)
  SETTINGS max_threads = 2, max_insert_threads = 1"
  m=$(( m + 1 ))
done
chq "OPTIMIZE TABLE lab.events_tiered FINAL SETTINGS optimize_throw_if_noop = 0"
chq "SELECT disk_name, count() AS parts, sum(rows) AS rows FROM system.parts
     WHERE database='lab' AND table='events_tiered' AND active
     GROUP BY disk_name FORMAT PrettyCompact"
snap 01_after_load

# ---------------------------------------------------------------- phase 02
echo ">> phase 02: apply TTL, wait for moves to settle"
chq "ALTER TABLE lab.events_tiered
     MODIFY TTL usage_date + INTERVAL $TTL_MONTHS MONTH TO VOLUME 'cold'"
chq "ALTER TABLE lab.events_tiered MATERIALIZE TTL SETTINGS mutations_sync = 2" 2>/dev/null || true
# wait until the hot/cold split stops changing
prev=""; stable=0
for i in $(seq 1 60); do
  cur=$(chq "SELECT groupArray(concat(disk_name,':',toString(c))) FROM
             (SELECT disk_name, count() AS c FROM system.parts
              WHERE database='lab' AND table='events_tiered' AND active
              GROUP BY disk_name ORDER BY disk_name)")
  [ "$cur" = "$prev" ] && stable=$(( stable + 1 )) || stable=0
  [ "$stable" -ge 3 ] && break
  prev="$cur"; sleep 10
done
chq "SELECT disk_name, count() AS parts, sum(rows) AS rows,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       min(partition) AS oldest, max(partition) AS newest
     FROM system.parts WHERE database='lab' AND table='events_tiered' AND active
     GROUP BY disk_name ORDER BY disk_name FORMAT PrettyCompact"
snap 02_after_ttl

# ---------------------------------------------------------------- phase 03
echo ">> phase 03: idle soak, ${SOAK_MINUTES} min, no queries and no inserts"
END=$(( $(date +%s) + SOAK_MINUTES * 60 ))
while [ "$(date +%s)" -lt "$END" ]; do sleep 30; done
snap 03_idle_soak

# ---------------------------------------------------------------- phase 04
echo ">> phase 04: benchmark reads across both tiers"
chq "SYSTEM DROP FILESYSTEM CACHE"
for q in \
  "SELECT count(), sum(cost) FROM lab.events_tiered" \
  "SELECT toYYYYMM(usage_date) m, sum(cost) FROM lab.events_tiered GROUP BY m ORDER BY m" \
  "SELECT service, sum(cost) FROM lab.events_tiered GROUP BY service ORDER BY 2 DESC"
do chq "$q" >/dev/null; done
snap 04_after_bench

# ---------------------------------------------------------------- phase 05
echo ">> phase 05: late-arriving row dated past the TTL (lands cold)"
chq "INSERT INTO lab.events_tiered VALUES
     (toDate('$START_DATE'), 'acct-late', 'AmazonEC2', 'us-east-1',
      'i-late-arrival', 1.0, 1.0, '{}')"
for i in $(seq 1 18); do sleep 10; done
chq "SELECT disk_name, count() AS parts FROM system.parts
     WHERE database='lab' AND table='events_tiered' AND active
     GROUP BY disk_name FORMAT PrettyCompact"
snap 05_late_insert

hr
echo "PHASE DELTAS"
hr
for pair in "00_baseline 01_after_load" "01_after_load 02_after_ttl" \
            "02_after_ttl 03_idle_soak" "03_idle_soak 04_after_bench" \
            "04_after_bench 05_late_insert"; do
  set -- $pair
  "$LAB_DIR/scripts/s3_counters.sh" diff "$1" "$2"
  echo
done
