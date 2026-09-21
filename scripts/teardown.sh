#!/usr/bin/env bash
# Stop the stack. Optionally delete the S3 prefix -- always with confirmation.
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo "This will stop the ch-s3-lab containers."
echo "S3 target: $S3_URI"
hr

read -r -p "Stop containers? [y/N] " a
case "$a" in
  [yY]*) docker compose down; echo "containers stopped (named volumes kept)";;
  *)     echo "left running";;
esac

echo
hr
echo "DESTRUCTIVE: deleting the S3 prefix removes all object data for"
echo "lab.events_s3. The table's metadata would survive but every read"
echo "would fail. This cannot be undone."
echo
if [ -n "${S3_CLI_ENDPOINT:-}" ]; then
  echo "  target : $S3_URI   (via $S3_CLI_ENDPOINT -- local MinIO)"
else
  echo "  target : $S3_URI   (REAL AWS S3)"
fi
SIZE=$(aws_s3 s3 ls --recursive --summarize "$S3_URI" 2>/dev/null | grep -E 'Total (Objects|Size)' | tr '\n' ' ')
echo "  current: ${SIZE:-<unreadable or empty>}"
echo
read -r -p "Type exactly 'delete $S3_BUCKET/$S3_PREFIX' to confirm, anything else to skip: " confirm
if [ "$confirm" = "delete $S3_BUCKET/$S3_PREFIX" ]; then
  echo "deleting $S3_URI ..."
  aws_s3 s3 rm --recursive "$S3_URI"
  echo "deleted."
else
  echo "skipped. S3 data left in place."
fi

echo
read -r -p "Also remove the local docker volumes (clickhouse metadata + minio data)? [y/N] " v
case "$v" in
  [yY]*) docker compose down -v; echo "volumes removed";;
  *)     echo "volumes kept";;
esac
