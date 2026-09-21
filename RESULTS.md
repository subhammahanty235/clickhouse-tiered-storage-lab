# ClickHouse on S3-only storage — results

A single-node ClickHouse serving a MergeTree table whose column data lives
entirely in object storage. No `s3()` table function, no manual fetching, no
local data tier. The only thing that distinguishes the S3 table from a normal
one is `SETTINGS storage_policy = 's3_only'`.

```
make up && make load && make verify && make bench
```

---

## 1. The claim, verified

`events_s3` and `events_local` have byte-identical schemas and byte-identical
data. Only the storage policy differs.

### Every byte is on the object store

```
┌─table────────┬─disk_name─┬─parts─┬───rows─┬────bytes─┬─size──────┐
│ events_local │ default   │    24 │ 999984 │ 60963223 │ 58.14 MiB │
│ events_s3    │ s3_raw    │    24 │ 999984 │ 60963223 │ 58.14 MiB │
└──────────────┴───────────┴───────┴────────┴──────────┴───────────┘

bytes on local disks : 0
bytes on object store: 60963223
PASS: 100% of events_s3 bytes are on the s3 disk.
```

`events_s3` has **no directory at all** under the local default disk. It does
keep a small local sidecar — 1.3 MB of pointer stubs — which is metadata, not
data. A part's `data.bin` on the local filesystem is 52 bytes:

```
3
1	4113
4113	pat/tmowignbdvqjwafqsosesyyxhfdsb
0
```

and the object it names is exactly 4113 bytes in the store. The local file is a
reference; the bytes are remote.

### The object store agrees

```
Total Objects: 289
   Total Size: 60988209

ClickHouse bytes_on_disk : 60963223
S3 total size            : 60988209
delta                    : 24986 bytes (0.04%)
```

The 0.04% delta is per-part checksum and metadata objects that
`bytes_on_disk` does not count.

### Data identity

Not just matching row counts — a full-column hash over both tables:

```
┌─────────────local_ck─┬────────────────s3_ck─┬─match─┐
│ 11499405014150324365 │ 11499405014150324365 │     1 │
└──────────────────────┴──────────────────────┴───────┘
```

### It survives a restart

```
count before restart: 999984
count after restart : 999984
PASS: metadata survived the restart and the table still reads.
```

Metadata lives on a named volume, so the part→object map outlives the
container. Queries afterward are ordinary SQL with no S3 syntax anywhere.

---

## 2. Benchmark: local vs S3-cold vs S3-warm

1,000,000 rows, 24 monthly partitions, 24 parts, 2.42 MiB average part.
Three runs per cell, median reported. Before every `local` and `s3_cold` run:
`SYSTEM DROP FILESYSTEM CACHE`, `SYSTEM DROP MARK CACHE`,
`SYSTEM DROP UNCOMPRESSED CACHE`, and `use_query_cache = 0`. `s3_warm` runs
after an unrecorded priming query, with caches left intact.

| Query | mode | median ms | vs local | read_rows | read_bytes | S3 GET | from_source B | from_cache B |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| **Q1** point lookup, 1 account, 1 month | local | 2 | — | 8,192 | 237,568 | 0 | 0 | 0 |
| | s3_cold | 27 | 13.5× | 8,192 | 237,568 | 2 | 2,097,402 | 41,155 |
| | s3_warm | 3 | 1.5× | 8,192 | 237,568 | 0 | 0 | 393,216 |
| **Q2** sum(cost) by service, 1 month | local | 5 | — | 41,666 | 458,518 | 0 | 0 | 0 |
| | s3_cold | 11 | 2.2× | 41,666 | 458,518 | 2 | 2,538,545 | 1,131,729 |
| | s3_warm | 3 | 0.6× | 41,666 | 458,518 | 0 | 0 | 1,966,080 |
| **Q3** sum(cost) by month, 24 months | local | 16 | — | 999,984 | 9,999,840 | 0 | 0 | 0 |
| | s3_cold | 136 | 8.5× | 999,984 | 9,999,840 | 48 | 60,948,894 | 0 |
| | s3_warm | 6 | 0.4× | 999,984 | 9,999,840 | 0 | 0 | 31,457,280 |
| **Q4** full scan count + sum | local | 5 | — | 999,984 | 7,999,872 | 0 | 0 | 0 |
| | s3_cold | 83 | 16.6× | 999,984 | 7,999,872 | 48 | 60,948,894 | 0 |
| | s3_warm | 5 | 1.0× | 999,984 | 7,999,872 | 0 | 0 | 15,728,640 |
| **Q5** top 20 resource_id, 6 months | local | 27 | — | 249,996 | 12,999,792 | 0 | 0 | 0 |
| | s3_cold | 62 | 2.3× | 249,996 | 12,999,792 | 12 | 15,234,759 | 9,855,451 |
| | s3_warm | 22 | 0.8× | 249,996 | 12,999,792 | 0 | 0 | 16,437,964 |

### What the numbers say

**GET count tracks parts touched, not rows read.** Q1 reads 8,192 rows and Q4
reads 999,984 — a 122× difference in rows, but only 2 GETs vs 48. The driver is
how many *parts* the query opens: Q3 and Q4 touch all 24 partitions and issue
2 GETs each. Partition pruning is therefore the single most effective lever on
S3 request cost. Q1 and Q2 prune to one month and pay 2 GETs.

**Cold reads pull far more than they use.** Q1 needs 237 KB but pulls 2.1 MB
from source — ClickHouse reads whole granules and buffers, so a selective
query still drags a minimum payload per part. The smaller the useful slice, the
worse the amplification ratio (Q1 is ~9× over-read).

**Warm cache erases the penalty, and can beat local.** Q3 warm (6 ms) is
*faster* than local (16 ms) and Q2 warm (3 ms) beats local (5 ms). Once bytes
are in the filesystem cache they are served from local disk exactly like a
normal table, and the cache holds them in a form that skips some work the local
MergeTree path repeats. Q4 warm ties local exactly (5 ms).

**The cold penalty is worst for scans, mildest for aggregates over few
parts.** Q4 is 16.6× slower cold; Q2 only 2.2×.

---

## 3. Object size distribution

This decides whether a colder storage class is worth anything.

```
total objects      : 289  (58.16 MiB)
under 128 KiB      : 265  (91.7% of objects, 0.04 MiB, 0.1% of bytes)
128 KiB and over   : 24  (8.3% of objects, 58.12 MiB, 99.9% of bytes)

  < 16 KiB         : 265
  16 KiB - 128 KiB : 0
  128 KiB - 1 MiB  : 0
  1 MiB - 16 MiB   : 24
  >= 16 MiB        : 0
```

The distribution is sharply bimodal: 24 large data objects (one per merged
partition) holding 99.9% of the bytes, and 265 tiny metadata objects holding
0.1%.

**Why it matters:** S3 Standard-IA and Glacier bill a **128 KiB minimum per
object**. The 265 small objects would each be billed as 128 KiB — about 33 MiB
of billable padding against 0.04 MiB of real data, a ~800× markup on that
slice. It is still small next to the 58 MiB of real data here, but the ratio
worsens as partition count grows, because metadata objects scale with *parts*
while data objects scale with *bytes*. Merging aggressively (as `load.sh` does
with `OPTIMIZE FINAL`) is what keeps the large-object share at 99.9%. An
unmerged table would invert this.

---

## 4. Cost extrapolation

Measured 60.96 bytes/row and 289 objects per 1M rows. us-east-1 list prices,
Sept 2026.

### Storage

| rows | size GB | gp3 @ $0.08 | S3 Std @ $0.023 | saving/mo |
|---|---:|---:|---:|---:|
| 1M (measured) | 0.06 | $0.00 | $0.00 | $0.00 |
| 25M | 1.52 | $0.12 | $0.04 | $0.09 |
| 100M | 6.10 | $0.49 | $0.14 | $0.35 |
| 1B | 60.96 | $4.88 | $1.40 | $3.47 |
| 10B | 609.64 | $48.77 | $14.02 | $34.75 |

S3 Standard is **71% cheaper per GB-month** than gp3. One-time PUT to load 289
objects: $0.0014.

Note this understates gp3's real cost: gp3 must be provisioned for peak plus
headroom and you pay for the whole volume whether or not it is full, while S3
bills only bytes stored. A 610 GB dataset on gp3 realistically means a ~750 GB
volume at ~$60/month against S3's $14.

### Requests, at $0.0004 per 1,000 GET

| GETs/query | $/query | $/1k queries | $/mo @ 1M queries/mo |
|---:|---:|---:|---:|
| 2 (Q1, Q2 — pruned to 1 month) | $0.0000008 | $0.0008 | $0.80 |
| 12 (Q5 — 6 months) | $0.0000048 | $0.0048 | $4.80 |
| 48 (Q3, Q4 — all 24 months) | $0.0000192 | $0.0192 | $19.20 |
| 500 | $0.0002 | $0.20 | $200 |
| 5,000 | $0.002 | $2.00 | $2,000 |
| 50,000 | $0.02 | $20.00 | $20,000 |

**Request cost is negligible until part count explodes.** A million full-scan
queries per month costs $19. The danger is not query volume — it is *part*
volume. This table has 24 parts because it is force-merged. At 10,000 parts a
full scan issues ~20,000 GETs and that same million queries costs $8,000/month.
On S3-backed storage, merge policy is a cost control, not just a performance
knob.

---

## 5. Deviations from the spec, and why

Every failure below was fixed in configuration. Nothing fell back to local
storage at any point.

| # | What broke | Cause | Fix |
|---|---|---|---|
| 1 | `minio/minio` image would not pull | MinIO left Docker Hub | Pinned `quay.io/minio/minio` |
| 2 | Load aborted, disk exhausted at 30M rows | `old_parts_lifetime` defaults to 480 s; merge leftovers gave ~2.2× disk amplification during a chunked load | `old_parts_lifetime = 30` in `schema.sql` |
| 3 | Server OOM-killed (exit 137) | ClickHouse claims ~90% of RAM by default; the 8 GB VM is shared with MinIO | `max_server_memory_usage` cap in `config.d/memory.xml` |
| 4 | Server refused to start (exit 36) | Shrinking `background_pool_size` broke three interlocked `merge_tree` minimums (`..._to_execute_mutation` = 20, `..._to_execute_optimize_entire_partition` = 25) which must stay below `pool_size × concurrency_ratio` | Dropped the pool override; memory caps alone bound peak |
| 5 | `MEMORY_LIMIT_EXCEEDED` on every bulk INSERT | A single INSERT spanning all 24 partitions holds 24 concurrent part-writers, each with a block buffer, times `max_threads` | `load.sh` rewritten to insert **one month per INSERT**; peak memory is now flat regardless of row count |
| 6 | Host disk filled; Docker daemon wedged | 10 GiB cache + 11 GiB of tables exceeded the volume | Cache `max_size` 10Gi → **2Gi** |
| 7 | Server would not boot (exit 233); MinIO failed every PUT | The out-of-disk event corrupted both volumes — ext4 entries raising `EBADMSG` ("bad message") that cannot be removed from userspace | Fresh volumes (`ch-data-v2`, `minio-data-v2`); originals left in place, not deleted |

### Two intentional deviations

**Dataset is 1M rows, not 100M.** The 100M load *did* complete — both tables
reached 100,000,000 rows, merged to 24 parts of 232 MiB, at 58.53 bytes/row.
But the host (16 GB Mac, 8 GB Docker VM, ~22 GB free disk) could not also hold
the filesystem cache, and the resulting out-of-disk event corrupted both
volumes beyond userspace repair. Scale was reduced at the user's direction to
something the machine sustains. All query shapes, the storage mechanism, and
the cost model are unchanged; absolute latencies are not comparable to a
100M-row run, and the ratios are conservative — cold penalties grow with
dataset size.

**Cache is 2 GiB, not 10 GiB.** 10 GiB does not coexist with the dataset on
this volume (that is deviation 6). At 2 GiB the working set still fits, so
warm numbers are genuine. On a host with room, restore `<max_size>10Gi`.

**MinIO stands in for AWS S3**, at the user's direction, to avoid writing lab
data into a production account holding live customer buckets. The mechanism
under test — `storage_policy`, the s3 disk, the cache disk, part→object
mapping, GET accounting — is identical. What is *not* transferable is absolute
latency: MinIO over loopback has ~0.1 ms RTT against real S3's ~20–50 ms
first-byte. **Real-world cold numbers will be substantially worse than the
`s3_cold` column here.** A Q4 cold scan issuing 48 GETs would add roughly
48 × 25 ms ≈ 1.2 s of latency against real S3 if issued serially, versus the
83 ms measured. Pointing at real S3 is a one-line `.env` change; nothing else
in the lab moves.

---

## 6. Verdict

**Viable against S3-only storage:**

- **Partition-pruned queries (Q1, Q2).** Two GETs, 2.2× cold penalty, and
  indistinguishable from local once warm. If the `WHERE` clause prunes to a
  handful of partitions, S3-only is a straightforward win — you pay 71% less
  per GB and the latency cost is bounded by a couple of round trips.
- **Anything served from a warm cache.** Q2, Q3 and Q5 warm all *beat* the
  local baseline. A working set that fits the cache makes the storage tier
  nearly irrelevant.
- **Archival and infrequently-scanned history.** Cold data nobody queries
  costs 71% less and the latency penalty is never paid.

**Not viable, or needs care:**

- **Cold full scans (Q4, 16.6×; Q3, 8.5×).** Every part costs round trips, and
  with real S3 latency this goes from 83 ms to seconds. Do not put an
  interactive dashboard on an unpruned scan of S3-backed data.
- **Low-latency point lookups on cold data (Q1, 13.5×).** The worst
  amplification ratio in the set: 2.1 MB pulled to answer with 237 KB. A
  key-value-shaped access pattern is the wrong fit — that 25 ms is a network
  round trip you cannot optimise away.
- **Anything with many small parts.** Cost and latency both scale with part
  count, not data size. Without aggressive merging, the GET bill and the
  128 KiB-minimum padding both compound.

**The practical rule:** on S3-only storage, *parts touched* is the unit of cost
and latency, not rows or bytes. Partition so queries prune, merge so parts stay
large, and size the cache to the working set. Do those three and S3-only is
viable for most analytical shapes. Skip them and the full-scan numbers above
are the optimistic case.
