-- Two tables, byte-identical schema. The ONLY difference is storage_policy.
-- Nothing in the DDL, and nothing a client does at query time, is aware of S3.

CREATE DATABASE IF NOT EXISTS lab;

-- ---------------------------------------------------------------- baseline
DROP TABLE IF EXISTS lab.events_local SYNC;
CREATE TABLE lab.events_local
(
    usage_date   Date,
    account_id   String,
    service      LowCardinality(String),
    region       LowCardinality(String),
    resource_id  String,
    usage_amount Float64,
    cost         Float64,
    tags         String
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(usage_date)
ORDER BY (account_id, service, usage_date)
SETTINGS old_parts_lifetime = 30;
-- default policy => local disk.
-- old_parts_lifetime: ClickHouse keeps post-merge leftovers for 480s by
-- default. During a chunked bulk load that is ~2.2x disk amplification on
-- top of the steady-state size -- enough to fill a small host volume before
-- the data itself is anywhere near the limit. 30s reclaims them promptly.

-- ------------------------------------------------------------ S3-only tier
DROP TABLE IF EXISTS lab.events_s3 SYNC;
CREATE TABLE lab.events_s3
(
    usage_date   Date,
    account_id   String,
    service      LowCardinality(String),
    region       LowCardinality(String),
    resource_id  String,
    usage_amount Float64,
    cost         Float64,
    tags         String
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(usage_date)
ORDER BY (account_id, service, usage_date)
SETTINGS storage_policy = 's3_only',
         old_parts_lifetime = 30;  -- see note on events_local above
