#!/usr/bin/env bash
# Cost extrapolation from the measured dataset + benchmark GET counts.
# Prices: us-east-1 list, Sept 2026.
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
require_up

GP3_PER_GB=0.08        # $/GB-month, gp3 provisioned
S3_STD_PER_GB=0.023    # $/GB-month, S3 Standard first 50TB
GET_PER_1000=0.0004    # $/1000 GET
PUT_PER_1000=0.005     # $/1000 PUT

BYTES=$(chq "SELECT sum(bytes_on_disk) FROM system.parts
             WHERE database='lab' AND table='events_s3' AND active")
ROWS=$(chq "SELECT sum(rows) FROM system.parts
            WHERE database='lab' AND table='events_s3' AND active")
OBJECTS=$(aws_s3 s3 ls --recursive "$S3_URI" 2>/dev/null | grep -cE '^[0-9]{4}-')

echo "measured: $ROWS rows, $BYTES bytes on disk, $OBJECTS S3 objects"
hr

awk -v bytes="$BYTES" -v objects="$OBJECTS" -v rows="$ROWS" \
    -v gp3="$GP3_PER_GB" -v s3p="$S3_STD_PER_GB" \
    -v getp="$GET_PER_1000" -v putp="$PUT_PER_1000" 'BEGIN {
  bpr = bytes / rows
  printf "bytes/row: %.2f   objects/1M rows: %.0f\n\n", bpr, objects * 1e6 / rows

  print "MONTHLY STORAGE, scaled at the measured bytes/row"
  printf "  %-14s %10s %12s %12s %12s\n", "rows", "size_GB", "gp3_$/mo", "S3_$/mo", "saving_$/mo"
  printf "  %-14s %10s %12s %12s %12s\n", "-------------", "--------", "----------", "---------", "-----------"
  n = split("1000000 25000000 100000000 1000000000 10000000000", sc, " ")
  for (i = 1; i <= n; i++) {
    r = sc[i] + 0; gb = r * bpr / 1e9
    printf "  %-14s %10.2f %12.2f %12.2f %12.2f\n", \
           (r >= 1e9 ? sprintf("%.0fB", r/1e9) : sprintf("%.0fM", r/1e6)), \
           gb, gb*gp3, gb*s3p, gb*(gp3-s3p)
  }
  printf "\n  S3 Standard is %.0f%% cheaper per GB-month than gp3.\n", (1 - s3p/gp3)*100
  printf "  One-time PUT to load %d objects: $%.4f\n", objects, objects*putp/1000

  printf "\nREQUEST COST, @ $%.4f per 1000 GET\n", getp
  printf "  %10s %14s %14s %16s\n", "GETs/query", "$/query", "$/1k queries", "$/mo @ 1M q/mo"
  printf "  %10s %14s %14s %16s\n", "---------", "----------", "-----------", "--------------"
  m = split("1 2 6 12 48 500 5000 50000", g, " ")
  for (i = 1; i <= m; i++) {
    q = g[i] + 0
    printf "  %10d %14.6f %14.4f %16.2f\n", q, q*getp/1000, q*getp, q*getp/1000*1e6
  }
}'
