#!/usr/bin/env bash
# Snapshot DiskS3* request counters, or diff two snapshots.
#
#   s3_counters.sh snap <label>     write results/counters/<label>.tsv
#   s3_counters.sh diff <a> <b>     print the delta b-a, with cost
#
# DiskS3* counts ONLY storage-disk traffic. The plain S3* counters also
# include table-function and backup traffic, which would pollute tiering
# numbers -- so everything here uses DiskS3*.
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

COUNTER_DIR="$LAB_DIR/results/counters"
mkdir -p "$COUNTER_DIR"

COUNTERS="DiskS3PutObject DiskS3UploadPart DiskS3CreateMultipartUpload \
DiskS3CompleteMultipartUpload DiskS3CopyObject DiskS3GetObject \
DiskS3ListObjects DiskS3DeleteObjects DiskS3ReadRequestsCount \
DiskS3WriteRequestsCount WriteBufferFromS3Bytes ReadBufferFromS3Bytes"

snap() {
  local label="$1"
  local list; list=$(echo $COUNTERS | tr ' ' '\n' | sed "s/.*/'&'/" | paste -sd, -)
  # system.events only materialises non-zero counters; coalesce the rest to 0.
  ch --query "
    WITH ev AS (SELECT event, value FROM system.events WHERE event IN ($list))
    SELECT name, toUInt64(ifNull((SELECT value FROM ev WHERE event = name), 0)) AS value
    FROM (SELECT arrayJoin([$list]) AS name)
    ORDER BY name FORMAT TSV" > "$COUNTER_DIR/$label.tsv"
  echo "snapshot '$label' -> results/counters/$label.tsv"
  awk -F'\t' '$2 > 0 {printf "   %-32s %12d\n", $1, $2}' "$COUNTER_DIR/$label.tsv"
  [ -s "$COUNTER_DIR/$label.tsv" ] || echo "   (all counters zero)"
}

diff_snaps() {
  local a="$1" b="$2"
  [ -f "$COUNTER_DIR/$a.tsv" ] || { echo "missing snapshot: $a" >&2; exit 1; }
  [ -f "$COUNTER_DIR/$b.tsv" ] || { echo "missing snapshot: $b" >&2; exit 1; }
  echo "delta: $a -> $b"
  join -t$'\t' "$COUNTER_DIR/$a.tsv" "$COUNTER_DIR/$b.tsv" | awk -F'\t' '
    BEGIN {
      put  = 0.005  / 1000   # PUT-class  $0.005/1k
      get  = 0.0004 / 1000   # GET-class  $0.0004/1k
      list = 0.005  / 1000   # LIST-class $0.005/1k
      printf "   %-32s %10s %12s\n", "counter", "delta", "cost_usd"
      printf "   %-32s %10s %12s\n", "--------------------------------", "---------", "-----------"
    }
    {
      d = $3 - $2
      if (d == 0) next
      c = 0; cls = ""
      if ($1 ~ /PutObject|UploadPart|MultipartUpload|CopyObject/) { c = d * put;  cls = "PUT" }
      else if ($1 ~ /GetObject/)   { c = d * get;  cls = "GET" }
      else if ($1 ~ /ListObjects/) { c = d * list; cls = "LIST" }
      else if ($1 ~ /DeleteObjects/) { c = 0; cls = "free" }
      if ($1 ~ /Bytes$/) { printf "   %-32s %10d %12s\n", $1, d, sprintf("%.2f MiB", d/1048576) }
      else               { printf "   %-32s %10d %12.6f  %s\n", $1, d, c, cls }
      total += c
    }
    END { printf "\n   %-32s %10s %12.6f\n", "TOTAL REQUEST COST", "", total }'
}

case "${1:-}" in
  snap) require_up; snap "${2:?label required}" ;;
  diff) diff_snaps "${2:?from}" "${3:?to}" ;;
  *) echo "usage: $0 snap <label> | diff <from> <to>" >&2; exit 1 ;;
esac
