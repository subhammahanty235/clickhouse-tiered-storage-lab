#!/usr/bin/env bash
# Measures what <prefer_not_to_merge> on the cold volume is worth, in S3
# requests, for a late-arriving row that lands straight into cold storage.
#
# Changing the volume setting requires a config change + restart, and a
# restart zeroes system.events. So this runs as its own segment with its own
# baseline rather than as another phase of tiering_experiment.sh.
#
#   prefer_not_to_merge_test.sh <label>
# Run once with the setting off, once with it on, then diff the two labels.
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_up

LABEL="${1:?label required, e.g. merge_on or merge_off}"
WAIT_S="${WAIT_S:-180}"

echo "prefer_not_to_merge test, label=$LABEL"
echo "cold volume setting currently:"
chq "SELECT volume_name, prefer_not_to_merge FROM system.storage_policies
     WHERE policy_name='tiered' FORMAT PrettyCompact" 2>/dev/null \
  || echo "  (column not exposed in this build; see config.d/tiered.xml)"
hr

"$LAB_DIR/scripts/s3_counters.sh" snap "pnm_${LABEL}_before" >/dev/null
echo "[baseline snapshot taken]"

# Ten separate inserts dated into the cold range: each creates a new part in
# an already-merged cold partition, which is exactly the situation that
# provokes merge churn against the bucket.
OLDEST=$(chq "SELECT min(usage_date) FROM lab.events_tiered")
echo "inserting 10 late rows dated $OLDEST (inside the cold range)"
for i in $(seq 1 10); do
  chq "INSERT INTO lab.events_tiered VALUES
       ('$OLDEST', 'acct-late-$i', 'AmazonEC2', 'us-east-1',
        'i-late-$i', 1.0, 1.0, '{}')"
done

echo "waiting ${WAIT_S}s for background merges to act"
END=$(( $(date +%s) + WAIT_S ))
while [ "$(date +%s)" -lt "$END" ]; do sleep 15; done

chq "SELECT disk_name, count() AS parts, sum(rows) AS rows FROM system.parts
     WHERE database='lab' AND table='events_tiered' AND active
     GROUP BY disk_name ORDER BY disk_name FORMAT PrettyCompact"

"$LAB_DIR/scripts/s3_counters.sh" snap "pnm_${LABEL}_after" >/dev/null
echo "[after snapshot taken]"
hr
"$LAB_DIR/scripts/s3_counters.sh" diff "pnm_${LABEL}_before" "pnm_${LABEL}_after"
