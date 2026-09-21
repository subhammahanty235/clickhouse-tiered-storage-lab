#!/usr/bin/env bash
# Shared helpers. Sourced by every script.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LAB_DIR"

[ -f .env ] || { echo "ERROR: .env missing. cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

# Bucket + prefix parsed out of S3_ENDPOINT so scripts stay endpoint-agnostic.
# Handles both  http://host:port/bucket/prefix/  and
#               https://bucket.s3.region.amazonaws.com/prefix/
_parse_endpoint() {
  local url="${S3_ENDPOINT%/}" host path
  host="${url#*://}"; path="${host#*/}"; host="${host%%/*}"
  if [[ "$host" == *.s3.*.amazonaws.com || "$host" == *.s3.amazonaws.com ]]; then
    S3_BUCKET="${host%%.s3.*}"; S3_PREFIX="$path"
  else
    S3_BUCKET="${path%%/*}"; S3_PREFIX="${path#*/}"
    [ "$S3_PREFIX" = "$S3_BUCKET" ] && S3_PREFIX=""
  fi
  export S3_BUCKET S3_PREFIX
  S3_URI="s3://${S3_BUCKET}/${S3_PREFIX:+${S3_PREFIX}/}"
  export S3_URI
}
_parse_endpoint

# aws wrapper: adds --endpoint-url only when S3_CLI_ENDPOINT is set (MinIO).
aws_s3() {
  if [ -n "${S3_CLI_ENDPOINT:-}" ]; then
    aws --endpoint-url "$S3_CLI_ENDPOINT" "$@"
  else
    aws "$@"
  fi
}

# clickhouse-client inside the container. Long timeouts: merges through S3
# take a while.
ch() {
  docker compose exec -T clickhouse clickhouse-client \
    --receive_timeout 7200 --send_timeout 7200 --max_execution_time 0 "$@"
}
chq() { ch --query "$1"; }

require_up() {
  docker compose exec -T clickhouse clickhouse-client --query "SELECT 1" >/dev/null 2>&1 \
    || { echo "ERROR: clickhouse not reachable. Run: make up" >&2; exit 1; }
}

hr() { printf '%*s\n' 74 '' | tr ' ' '-'; }
