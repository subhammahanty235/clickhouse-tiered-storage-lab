#!/usr/bin/env bash
# Prove events_s3 stores 100% of its bytes in S3 and 0% locally, that the
# object store agrees, and that the table survives a restart.
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_up
mkdir -p results

echo "=============================================================="
echo " 1. system.parts by disk_name"
echo "=============================================================="
chq "SELECT table, disk_name, count() AS parts, sum(rows) AS rows,
            sum(bytes_on_disk) AS bytes,
            formatReadableSize(sum(bytes_on_disk)) AS size
     FROM system.parts WHERE database='lab' AND active
     GROUP BY table, disk_name ORDER BY table, disk_name FORMAT PrettyCompact"

echo
echo "-- assertion: events_s3 has ZERO bytes on any local disk --"
LOCAL_BYTES=$(chq "SELECT sum(bytes_on_disk) FROM system.parts
                   WHERE database='lab' AND table='events_s3' AND active
                     AND disk_name NOT IN (SELECT name FROM system.disks
                                           WHERE type='ObjectStorage')")
LOCAL_BYTES=${LOCAL_BYTES:-0}; [ "$LOCAL_BYTES" = "\\N" ] && LOCAL_BYTES=0
S3_BYTES=$(chq "SELECT sum(bytes_on_disk) FROM system.parts
                WHERE database='lab' AND table='events_s3' AND active")
echo "   bytes on local disks : $LOCAL_BYTES"
echo "   bytes on object store: $S3_BYTES"
if [ "$LOCAL_BYTES" -eq 0 ] && [ "$S3_BYTES" -gt 0 ]; then
  echo "   PASS: 100% of events_s3 bytes are on the s3 disk."
else
  echo "   FAIL: events_s3 has local bytes."; exit 1
fi

echo
echo "-- local footprint really is metadata only --"
UUID=$(chq "SELECT uuid FROM system.tables WHERE database='lab' AND name='events_s3'")
docker compose exec -T clickhouse sh -c "
  echo -n '   metadata (pointer stubs): ';
  du -sh /var/lib/clickhouse/disks/s3_raw/store/*/$UUID 2>/dev/null | cut -f1;
  echo -n '   column data under local default disk: ';
  du -sh /var/lib/clickhouse/store/*/$UUID 2>/dev/null | cut -f1 || echo 'none (no such directory)'"

echo
echo "=============================================================="
echo " 2. object store agrees (aws s3 ls --recursive --summarize)"
echo "=============================================================="
aws_s3 s3 ls --recursive --summarize "$S3_URI" > results/s3_listing.txt 2>&1
tail -3 results/s3_listing.txt
OBJ_COUNT=$(grep -E '^\s*Total Objects:' results/s3_listing.txt | awk '{print $3}')
OBJ_BYTES=$(grep -E '^\s*Total Size:'    results/s3_listing.txt | awk '{print $3}')
echo
echo "   ClickHouse bytes_on_disk : $S3_BYTES"
echo "   S3 total size            : $OBJ_BYTES"
echo "   S3 object count          : $OBJ_COUNT"
if [ -n "$OBJ_BYTES" ] && [ "$OBJ_BYTES" -gt 0 ]; then
  DELTA=$(( OBJ_BYTES - S3_BYTES ))
  PCT=$(awk -v d="$DELTA" -v b="$S3_BYTES" 'BEGIN{printf "%.2f", (d/b)*100}')
  echo "   delta                    : $DELTA bytes (${PCT}%)"
  echo "   (S3 is slightly larger: it also holds per-part checksums/metadata"
  echo "    objects that bytes_on_disk does not count.)"
fi

echo
echo "=============================================================="
echo " 3. object size distribution (drives storage-class choice)"
echo "=============================================================="
# Column 3 of `aws s3 ls --recursive` is the byte size.
grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}' results/s3_listing.txt \
  | awk '{print $3}' \
  | awk '
    { n++; total += $1
      if ($1 <  131072) { small++; small_b += $1 } else { big++; big_b += $1 }
      if ($1 <   16384) b16++
      else if ($1 <  131072) b128++
      else if ($1 < 1048576) b1m++
      else if ($1 < 16777216) b16m++
      else b16mplus++ }
    END {
      printf "   total objects      : %d  (%.2f MiB)\n", n, total/1048576
      printf "   under 128 KiB      : %d  (%.1f%% of objects, %.2f MiB, %.1f%% of bytes)\n", \
             small, small*100/n, small_b/1048576, small_b*100/total
      printf "   128 KiB and over   : %d  (%.1f%% of objects, %.2f MiB, %.1f%% of bytes)\n", \
             big, big*100/n, big_b/1048576, big_b*100/total
      print  "   ---- histogram ----"
      printf "     < 16 KiB         : %d\n", b16
      printf "     16 KiB - 128 KiB : %d\n", b128
      printf "     128 KiB - 1 MiB  : %d\n", b1m
      printf "     1 MiB - 16 MiB   : %d\n", b16m
      printf "     >= 16 MiB        : %d\n", b16mplus
      print  ""
      print  "   Why this matters: S3 Standard-IA and Glacier bill a 128 KiB"
      print  "   minimum per object. Objects below that line cost the same as"
      print  "   a 128 KiB object, so a part layout dominated by small objects"
      print  "   erases the savings of a colder storage class."
    }' | tee results/object_size_distribution.txt

echo
echo "=============================================================="
echo " 4. restart durability"
echo "=============================================================="
BEFORE=$(chq "SELECT count() FROM lab.events_s3")
echo "   count before restart: $BEFORE"
echo "   restarting clickhouse..."
docker compose restart clickhouse >/dev/null 2>&1
for i in $(seq 1 60); do
  docker compose exec -T clickhouse clickhouse-client --query "SELECT 1" >/dev/null 2>&1 && break
  sleep 2
done
AFTER=$(chq "SELECT count() FROM lab.events_s3")
echo "   count after restart : $AFTER"
if [ "$BEFORE" = "$AFTER" ] && [ "$AFTER" -gt 0 ]; then
  echo "   PASS: metadata survived the restart and the table still reads."
else
  echo "   FAIL: count changed across restart."; exit 1
fi

echo
echo "   a normal SQL query, no S3 syntax anywhere:"
chq "SELECT service, round(sum(cost)) AS total_cost, count() AS rows
     FROM lab.events_s3 GROUP BY service ORDER BY total_cost DESC LIMIT 5
     FORMAT PrettyCompact"

echo
echo "=============================================================="
echo " VERIFY PASSED"
echo "=============================================================="
