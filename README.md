# clickhouse-tiered-storage-lab

A self-contained lab that runs ClickHouse with **S3 as a storage tier** and
measures what it costs in latency and requests.

Two things are demonstrated, both reproducible with `make`:

1. **S3-only** — a MergeTree table whose data lives entirely in object
   storage. Zero bytes on local disk.
2. **Tiered (EBS → S3)** — one table spanning two tiers: recent partitions on
   local disk, older partitions on S3, queried with a single `SELECT`.

No `s3()` table function, no manual downloads, no application-side stitching.
The only thing that differs from a normal table is `storage_policy`.

---

## Quick start

```bash
cp .env.example .env
make up          # start minio + clickhouse
make load        # generate rows into both tables, force merges
make verify      # prove data is on S3 and survives restart
make bench       # local vs s3-cold vs s3-warm
make costs       # storage + request extrapolation
make shell       # interactive clickhouse-client
```

Default is 1M rows over 24 months. Override with `make load TOTAL_ROWS=25000000`.

MinIO stands in for AWS S3 so the lab runs offline and costs nothing. The
mechanism under test is identical; only absolute latency differs (see
[Caveats](#caveats)). Pointing at real S3 is a one-line `.env` change.

---

## How it works

### The storage policy is the whole trick

ClickHouse tracks storage per **part**, not per table. A disk of type `s3`
holds column data as objects; a `cache` disk wraps it with a local
read-through cache. A policy groups disks into volumes:

```xml
<disks>
  <s3_raw>                              <!-- raw object storage -->
    <type>s3</type>
    <endpoint from_env="S3_ENDPOINT"/>
    <use_environment_credentials>true</use_environment_credentials>
    <metadata_path>/var/lib/clickhouse/disks/s3_raw/</metadata_path>
  </s3_raw>
  <s3_cached>                           <!-- read-through cache over it -->
    <type>cache</type>
    <disk>s3_raw</disk>
    <max_size>2Gi</max_size>
  </s3_cached>
</disks>
```

A table opts in with one setting:

```sql
CREATE TABLE events_s3 (...) ENGINE = MergeTree
PARTITION BY toYYYYMM(usage_date)
ORDER BY (account_id, service, usage_date)
SETTINGS storage_policy = 's3_only';
```

Clients cannot tell the difference. Same SQL, same drivers, same everything.

### What actually lives locally

A small metadata sidecar — pointer stubs, not data. A part's `data.bin` on
local disk is 52 bytes:

```
3
1	4113
4113	pat/tmowignbdvqjwafqsosesyyxhfdsb
0
```

and the object it names is exactly 4,113 bytes in S3. In the 1M-row run the
entire local footprint was **1.3 MB of metadata against 58 MB of data** (~2%).
That metadata sits on a named volume, so the part→object map survives restarts.

### Tiering: one table, two tiers

Add a second volume and parts can live on either disk:

```xml
<tiered>
  <volumes>
    <hot>  <disk>default</disk>   <move_factor>0.2</move_factor> </hot>
    <cold> <disk>s3_cached</disk> </cold>
  </volumes>
</tiered>
```

Age data down automatically:

```sql
ALTER TABLE events_tiered
MODIFY TTL usage_date + INTERVAL 12 MONTH TO VOLUME 'cold';
```

Parts migrate to S3 on their own as they cross 12 months. `move_factor` is a
second trigger: when the hot volume passes ~80% full, the oldest parts get
pushed down regardless of age, so local disk cannot fill up.

**A part never spans disks.** The boundary sits at partition granularity, so
partition on the column you age by.

---

## Output

### Proof the data is on S3

```
┌─table────────┬─disk_name─┬─parts─┬───rows─┬────bytes─┬─size──────┐
│ events_local │ default   │    24 │ 999984 │ 60963223 │ 58.14 MiB │
│ events_s3    │ s3_raw    │    24 │ 999984 │ 60963223 │ 58.14 MiB │
└──────────────┴───────────┴───────┴────────┴──────────┴───────────┘

bytes on local disks : 0
bytes on object store: 60963223
PASS: 100% of events_s3 bytes are on the s3 disk.
```

The object store agrees: **289 objects, 60,988,209 bytes** (0.04% larger —
per-part checksum objects `bytes_on_disk` does not count). Both tables hold
byte-identical data, proven by a matching full-column hash, not just row counts.

### A single query spanning both tiers

Twelve months on S3, twelve on local disk, in one table:

```
┌─disk_name─┬─parts─┬─first_month─┬─last_month─┬───rows─┐
│ default   │    12 │ 202501      │ 202512     │ 499992 │
│ s3_raw    │    12 │ 202401      │ 202412     │ 499992 │
└───────────┴───────┴─────────────┴────────────┴────────┘
```

One `SELECT` across the boundary (Jun 2024 → Jun 2025) returns 13 months as a
single result set:

```
query_duration_ms: 168
read_rows:         541658
s3_gets:           21
```

The 21 GETs confirm it genuinely read S3 for the older half while the newer
half came off local disk — one query pipeline, no merging on your side.

### Benchmark

1M rows, 24 parts. Median of 3. All caches dropped before every cold run.

| Query | local | S3 cold | S3 warm | GETs |
|---|---:|---:|---:|---:|
| Q1 point lookup, 1 account, 1 month | 2 ms | 27 ms (13.5×) | 3 ms | 2 |
| Q2 sum(cost) by service, 1 month | 5 ms | 11 ms (2.2×) | 3 ms | 2 |
| Q3 sum(cost) by month, 24 months | 16 ms | 136 ms (8.5×) | 6 ms | 48 |
| Q4 full scan | 5 ms | 83 ms (16.6×) | 5 ms | 48 |
| Q5 top 20 resource_id, 6 months | 27 ms | 62 ms (2.3×) | 22 ms | 12 |

**GET count tracks parts touched, not rows.** Q1 reads 8K rows and Q4 reads
1M — 122× the rows, but 2 GETs vs 48. Partition pruning is the cost lever.

**A warm cache erases the penalty and can beat local.** Q2, Q3 and Q5 warm all
run faster than the local baseline.

---

## Cost: before and after tiering

Measured **60.96 bytes/row** and **289 objects per 1M rows**. Prices are
us-east-1 list (gp3 $0.08/GB-month, S3 Standard $0.023/GB-month, GET
$0.0004/1,000). gp3 is provisioned at 1.3× the dataset for headroom, since you
pay for the volume whether or not it is full; S3 bills only bytes stored.

### Worked example — 2 TB of billing data over 24 months

**Before — everything on gp3:**

```
2,000 GB x 1.3 provisioned x $0.08  =  $208.00 / month
```

**After — recent months hot, the rest aged to S3:**

| hot months | gp3 GB | S3 GB | before/mo | after/mo | saving | % |
|---:|---:|---:|---:|---:|---:|---:|
| 24 (no tiering) | 2000 | 0 | $208.00 | $208.00 | $0.00 | 0% |
| 12 | 1000 | 1000 | $208.00 | $127.00 | $81.00 | **39%** |
| 6 | 500 | 1500 | $208.00 | $86.50 | $121.50 | **58%** |
| 3 | 250 | 1750 | $208.00 | $66.25 | $141.75 | **68%** |
| 1 | 83 | 1917 | $208.00 | $52.75 | $155.25 | **75%** |

The same percentages hold at any scale, since both tiers are linear in GB:

| dataset | before/mo | after/mo (3 months hot) | saving/mo |
|---|---:|---:|---:|
| 60 GB (1B rows) | $6.34 | $2.02 | $4.32 |
| 500 GB | $52.00 | $16.56 | $35.44 |
| 2 TB | $208.00 | $66.25 | $141.75 |
| 10 TB | $1,040.00 | $331.25 | $708.75 |

### The cost that replaces it: requests

Egress is **not** the driver. S3 → EC2 in the same region is **$0.00** — the
$0.07–0.09/GB figure people quote is transfer out to the *internet*. What you
pay instead is GET requests, and they scale with parts touched:

| parts scanned | GETs | $/query | $/month @ 100k queries |
|---:|---:|---:|---:|
| 1 (pruned to one partition) | 2 | $0.000001 | $0.08 |
| 24 (full scan, merged) | 48 | $0.000019 | $1.92 |
| 1,000 | 2,000 | $0.000800 | $80.00 |
| 5,000 (unmerged) | 10,000 | $0.004000 | $400.00 |

A merged table scanned 100,000 times a month costs **$1.92** in requests. The
same data left unmerged at 5,000 parts costs **$400** — 200× more, for
identical bytes. On S3-backed storage, merge policy is a cost control.

> **Watch for NAT Gateway.** If your EC2 reaches S3 through a NAT Gateway
> instead of an **S3 Gateway VPC Endpoint**, you pay $0.045/GB in NAT data
> processing — charges that look exactly like the egress you thought you were
> avoiding. Gateway endpoints are free. This is the single most common
> avoidable cost in S3-heavy setups.

---

## Verdict

**Works well on S3:**
- Partition-pruned queries — 2 GETs, 2.2× cold penalty, indistinguishable from
  local once warm
- Anything served from a warm cache — several queries *beat* the local baseline
- Archival history nobody scans — 71% cheaper per GB, latency penalty never paid

**Needs care:**
- Cold full scans — 16.6× here, and worse against real S3 latency. Don't put an
  interactive dashboard on an unpruned scan of cold data.
- Low-latency point lookups on cold data — 13.5×, and 2.1 MB pulled to answer
  with 237 KB. A key-value access pattern is the wrong fit.
- Tables with many small parts — cost and latency scale with part count, not
  data size.

**The rule:** on S3-backed storage, *parts touched* is the unit of cost and
latency, not rows or bytes. Partition so queries prune, merge so parts stay
large, size the cache to the working set.

---

## Caveats

- **MinIO is not S3 for latency.** Loopback is ~0.1 ms; real S3 first-byte is
  20–50 ms. A cold Q4 issuing 48 GETs would add roughly 1.2 s against real S3
  versus the 83 ms measured. **The cold column is optimistic.** Storage
  mechanics, GET accounting and cost modelling all transfer; absolute cold
  latency does not.
- **1M rows, not 100M.** A 100M run completed (24 parts of 232 MiB, 58.53
  bytes/row) but exhausted the dev machine's disk. Scale was reduced to what
  the host sustains. Ratios are conservative — cold penalties grow with size.
- **Cache is 2 GiB.** Sized to this host. Raise `<max_size>` in
  `config.d/s3.xml` if you have room.
- **Single node.** Zero-copy replication is explicitly disabled.

See [RESULTS.md](RESULTS.md) for full measurements and the seven configuration
problems hit along the way, with causes and fixes.

---

## Layout

```
docker-compose.yml       minio + clickhouse 25.8.33.6, named volumes
config.d/s3.xml          s3 disk, cache disk, s3_only policy
config.d/tiered.xml      two-volume hot/cold policy
config.d/memory.xml      memory caps for a small VM
sql/schema.sql           events_local (baseline) + events_s3 (S3-only)
scripts/load.sh          generate + load both tables, force merges
scripts/verify.sh        prove S3-only, object counts, size histogram, restart
scripts/bench.sh         Q1-Q5 x local/cold/warm, pulls ProfileEvents
scripts/costs.sh         storage + request extrapolation
scripts/teardown.sh      stop containers, optionally delete the S3 prefix
```
