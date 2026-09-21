.PHONY: up load verify bench costs down teardown logs shell

# Rows to generate. The spec's target is 100M; this host sustains 1M.
# Override:  make load TOTAL_ROWS=25000000
TOTAL_ROWS ?= 1000000

up:      ## start minio + clickhouse, wait for health
	@[ -f .env ] || cp .env.example .env
	docker compose up -d
	@printf 'waiting for clickhouse'
	@for i in $$(seq 1 60); do \
	   docker compose exec -T clickhouse clickhouse-client --query "SELECT 1" >/dev/null 2>&1 && break; \
	   printf '.'; sleep 2; done; echo
	@docker compose exec -T clickhouse clickhouse-client --query \
	   "SELECT 'clickhouse ' || version() || ' up'"
	@docker compose exec -T clickhouse clickhouse-client --query \
	   "SELECT name, type FROM system.disks FORMAT PrettyCompact"

load:    ## generate rows into both tables and force merges (TOTAL_ROWS=n)
	TOTAL_ROWS=$(TOTAL_ROWS) ./scripts/load.sh

verify:  ## prove events_s3 is 100% on S3 and survives restart
	./scripts/verify.sh

bench:   ## run the query set: local vs s3-cold vs s3-warm
	./scripts/bench.sh

costs:   ## storage + request cost extrapolation from measured data
	./scripts/costs.sh

down:    ## stop containers, keep volumes
	docker compose down

teardown: ## interactive: stop + optionally delete S3 prefix and volumes
	./scripts/teardown.sh

logs:    ## tail clickhouse logs
	docker compose logs -f clickhouse

shell:   ## interactive clickhouse-client prompt
	docker compose exec clickhouse clickhouse-client
