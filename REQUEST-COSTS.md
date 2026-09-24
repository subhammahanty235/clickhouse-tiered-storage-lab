# S3 request costs in a tiered ClickHouse setup

Answering a fair challenge: the per-GB storage gap is real, but request charges
and background merge churn are where tiered setups get their surprise. So
what does the request bill actually look like?

This measures `DiskS3*` ProfileEvents across the lifecycle of a tiered table.
`DiskS3*` counts **only storage-disk traffic**; the plain `S3*` counters also
include table-function and backup traffic, which would pollute the numbers.

Reproduce with:

```bash
make up
SOAK_MINUTES=45 ./scripts/tiering_experiment.sh
./scripts/prefer_not_to_merge_test.sh merge_allowed
# then set <prefer_not_to_merge>true</prefer_not_to_merge> on the cold volume, restart
./scripts/prefer_not_to_merge_test.sh merge_suppressed
```

**Setup:** 1M rows, 24 monthly partitions, `TTL usage_date + INTERVAL 12 MONTH
TO VOLUME 'cold'`, `merge_with_ttl_timeout = 60`. After the TTL settled: 13
partitions hot on local disk (`202509`–`202609`), 11 cold on S3
(`202410`–`202508`), 24.84 MiB cold.

`system.events` is cumulative since server start, so every phase is a snapshot
and every number below is a **delta**, not a running total. The server was not
restarted mid-run.

---

## Phase deltas

| phase | PUT | GET | DELETE | bytes to S3 | cost |
|---|---:|---:|---:|---:|---:|
| 01 load 1M rows to hot tier | 0 | 0 | 0 | 0 | **$0.000000** |
| 02 TTL move, 11 partitions | 143 | 121 | 0 | 24.85 MiB | **$0.000763** |
| 03 idle soak, 45 min | 0 | 0 | 0 | 0 | **$0.000000** |
| 04 three queries across both tiers | 0 | 22 | 0 | — | **$0.000009** |
| 05 one late row dated into cold | 13 | 0 | 0 | 2.1 KB | **$0.000065** |

PUT-class $0.005/1k, GET-class $0.0004/1k, DELETE free.

### 01 — loading the hot tier costs nothing

Exactly zero S3 requests during ingest. Nothing reached the bucket, confirming
no data moved earlier than intended.

### 02 — migration is a real one-time cost, driven by object count

143 PUTs to move 11 partitions: **~13 objects per part**. A part is not one
object — it is `data.bin`, marks, the primary index, `count.txt`,
`checksums.txt`, `columns.txt` and so on, each PUT separately.

Normalised: **$0.031 per GB migrated.** Moving a GB into S3 costs roughly 1.4
months of storing it there. It pays back quickly, but it is not free, and it is
why month one of a tiering rollout can look worse than expected.

Because the cost scales with *parts × files-per-part*, not bytes, migrating
many small partitions is far more expensive per GB than migrating few large
ones.

**No multipart here.** `DiskS3UploadPart`, `DiskS3CreateMultipartUpload` and
`DiskS3CompleteMultipartUpload` were all 0, because these parts are ~2.3 MB —
under the single-upload threshold. At the 232 MiB parts from a 100M-row run,
multipart *would* engage and add `CreateMultipartUpload` + N×`UploadPart` +
`CompleteMultipartUpload` per part. The PUT profile changes shape with part
size; don't generalise from one part size to another.

### 03 — idle churn was zero

**45 minutes, no queries, no inserts: not a single request.**

This is the number the challenge was really about, and the answer here is
nothing — but the reason matters more than the number.

The cold tier was **fully merged**: one part per partition. Background merges
need at least two parts in a partition to have anything to do. With one part
each, there is no merge to schedule, so nothing touches the bucket.

So "background merges quietly hitting the bucket" is **not an unconditional
property of tiered storage**. It is a property of a cold tier that still has
multiple parts per partition. That happens when data arrives late, when TTL
moves land parts alongside existing ones, or when you never force-merged
before ageing data down. Force-merge before the TTL move and idle churn goes
to zero.

### 04 — reads are the cheap part

Three queries scanning the whole table, caches dropped: 22 GETs, $0.000009.
With 11 cold parts that is **exactly 2 GETs per part**. Re-measured later at 21
cold parts: exactly 42. The relationship is linear and exact:

```
GETs per cold scan = 2 x (cold parts touched)
```

Partition pruning removes parts from that count, which is why it is the main
lever on read cost.

### 05 — a single late row costs 13 PUTs

One row dated into the cold range: 13 PUTs, $0.000065. Because
`perform_ttl_move_on_insert = 1` (the default), it went straight to S3 as a new
part — and a new part means a fresh set of ~13 objects, regardless of holding
one row.

**Late-arriving data is billed per part, not per byte.** A thousand
late-arriving rows trickling in as a thousand separate inserts costs ~13,000
PUTs ($0.065); the same thousand rows in one insert costs 13 ($0.000065). Batch
late arrivals.

---

## What `prefer_not_to_merge` is worth

Ten separate late-arriving inserts into an already-merged cold partition —
the situation that actually provokes merge churn. Identical start state (11
cold parts) both runs, 180 s settle time.

| | merging allowed (default) | `prefer_not_to_merge` |
|---|---:|---:|
| `DiskS3PutObject` | 182 | **130** |
| `DiskS3GetObject` | 26 | **0** |
| `DiskS3DeleteObjects` | 14 | **0** |
| bytes written to S3 | 4.55 MiB | **0.02 MiB** |
| **request cost** | **$0.000920** | **$0.000650** |
| cold parts afterwards | 12 | **21** |

**Merge churn is real, and it is mostly write amplification.** 4.55 MiB written
to store ten rows of actual data. Merging read the existing parts back (26
GETs), rewrote them as new objects (52 extra PUTs), then deleted the originals
(14 DELETEs). Suppressing it cut bytes written by **99.6%** and request cost by
**29%**.

The 130 PUTs in the right-hand column are the irreducible floor: ten inserts ×
13 objects. `prefer_not_to_merge` eliminates the *rewrite*, not the write.

### But it is a trade, not a win

Suppressing merges left **21 cold parts instead of 12**. At 2 GETs per part,
every subsequent full scan costs 42 GETs instead of 24 — forever, until
something merges them.

```
merge cost (one-off)      = $0.000920 - $0.000650 = $0.000270
read saving (per scan)    = 9 parts x 2 GETs x $0.0000004 = $0.0000072
crossover                 = 0.000270 / 0.0000072 ≈ 38 scans
```

**Scan that partition more than ~38 times and merging has already paid for
itself.** For cold data genuinely queried a handful of times a year,
`prefer_not_to_merge` wins. For cold data on a dashboard, it loses, and it
loses continuously.

That crossover is the number worth computing for your own access pattern; the
inputs are just part count and scan frequency.

---

## Summary

- Loading the hot tier: **free**.
- TTL migration: **$0.031/GB**, one-off, scaling with part count not bytes.
- Idle churn on a **fully merged** cold tier: **zero**. On an unmerged one it
  is write amplification, and it is the real surprise.
- Reads: **2 GETs per cold part**, exactly. Prune partitions to reduce it.
- Late arrivals: **13 PUTs per part** regardless of row count. Batch them.
- `prefer_not_to_merge`: saves 29% of write cost and 99.6% of bytes, at the
  price of permanently higher read cost. Crossover here was ~38 scans.

The general rule from the earlier benchmark holds and is now quantified on the
write side too: **parts are the unit of cost**, on reads *and* writes. Storage
is priced per GB; everything else is priced per part.

---

## Caveats

- **MinIO, not AWS S3.** Request *counts* are exact and counts are what AWS
  bills, so the cost arithmetic transfers directly. Latency does not — see
  README.
- **1M rows, ~2.3 MB parts.** Large enough to exercise every code path, small
  enough to stay under the multipart threshold. A production-sized part
  (100 MB+) shifts PUTs into multipart and changes the per-part object count.
- **`perform_ttl_move_on_insert = 1`** (the default) throughout. Setting it to
  0 makes late rows land hot and migrate later in a batch, which should cut the
  per-row PUT cost — not tested here.
- **Single node**, zero-copy replication disabled. On a replicated cluster,
  zero-copy changes the write accounting substantially.
