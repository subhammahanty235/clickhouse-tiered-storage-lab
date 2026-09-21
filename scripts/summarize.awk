# Median duration + GET count per (query, table, mode).
# Keying on table matters: the local baseline and the s3 cold run are both
# "cold" (caches dropped), and collapsing them loses the baseline entirely.
BEGIN { FS = "\t" }
NR > 1 {
  label = ($2 == "events_local") ? "local" : ($3 == "warm" ? "s3_warm" : "s3_cold")
  key = $1 "\t" label
  dur[key]  = dur[key] " " $5
  get[key]  = get[key] " " $8
  rows[key] = $6; bytes[key] = $7
  src[key]  = $11; cch[key] = $12
  seen[$1]  = 1
}
function median(list,   n, i, j, t, a, c, v) {
  n = split(list, a, " "); c = 0
  for (i = 1; i <= n; i++) if (a[i] != "") v[++c] = a[i] + 0
  for (i = 1; i < c; i++) for (j = i + 1; j <= c; j++) if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
  if (c == 0) return 0
  return (c % 2) ? v[(c + 1) / 2] : (v[c / 2] + v[c / 2 + 1]) / 2
}
END {
  printf "%-4s %-9s %10s %11s %12s %8s %14s %14s\n", \
         "Q", "mode", "median_ms", "read_rows", "read_bytes", "S3_GET", "from_source_B", "from_cache_B"
  printf "%-4s %-9s %10s %11s %12s %8s %14s %14s\n", \
         "----", "--------", "---------", "----------", "-----------", "-------", "-------------", "------------"
  n = split("Q1 Q2 Q3 Q4 Q5", qs, " ")
  m = split("local s3_cold s3_warm", ms, " ")
  for (i = 1; i <= n; i++) {
    if (!(qs[i] in seen)) continue
    for (j = 1; j <= m; j++) {
      k = qs[i] "\t" ms[j]
      if (!(k in dur)) continue
      printf "%-4s %-9s %10d %11d %12d %8d %14d %14d\n", \
             qs[i], ms[j], median(dur[k]), rows[k], bytes[k], median(get[k]), src[k], cch[k]
    }
    print ""
  }
}
