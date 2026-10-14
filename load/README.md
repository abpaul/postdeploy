# Ingestion resilience load tests

Run these tests only against local or founder-approved non-production targets.

The generator uses real HTTP, authentication, JSON serialization, request limits, and normal controllers. One Observe request contains ten events by default.

Set enough keys from separate organizations to satisfy commercial quotas. Safety limits still apply before commercial allowance.

## Commands

```bash
BASE_URL=http://127.0.0.1:4000 ALPLUS_KEYS=key1,key2,... PROFILE=million_60m k6 run load/k6/ingestion.js
BASE_URL=http://127.0.0.1:4000 ALPLUS_KEYS=key1,key2,... PROFILE=million_30m k6 run load/k6/ingestion.js
BASE_URL=http://127.0.0.1:4000 ALPLUS_KEYS=key1,key2,... PROFILE=million_10m k6 run load/k6/ingestion.js
BASE_URL=http://127.0.0.1:4000 ALPLUS_KEYS=key1,key2,... PROFILE=burst_5k k6 run load/k6/ingestion.js
BASE_URL=http://127.0.0.1:4000 ALPLUS_KEYS=one-key PROFILE=noisy_tenant k6 run load/k6/ingestion.js
BASE_URL=http://127.0.0.1:4000 ALPLUS_KEYS=key1,key2,... PROFILE=many_tenants k6 run load/k6/ingestion.js
BASE_URL=http://127.0.0.1:4000 ALPLUS_KEYS=one-key PROFILE=invalid_flood k6 run load/k6/ingestion.js
```

Start the server with database delay for the slowdown profile:

```bash
INGEST_DB_DELAY_MS=250 POOL_SIZE=10 INGEST_POOL_SIZE=4 mix phx.server
BASE_URL=http://127.0.0.1:4000 ALPLUS_KEYS=key1,key2 PROFILE=database_slowdown k6 run load/k6/ingestion.js
```

Pause and resume local Postgres during the recovery profile:

```bash
BASE_URL=http://127.0.0.1:4000 ALPLUS_KEYS=key1,key2 PROFILE=outage_recovery k6 run load/k6/ingestion.js
docker pause alplus-postgres-1
docker unpause alplus-postgres-1
```

Use `KIND=sessions`, `KIND=measure`, or `KIND=heartbeat` with the corresponding token variable to test another path.

The test fails when unexpected responses reach 1%, p95 exceeds 2 seconds, or p99 exceeds 5 seconds. A `429` or `503` is deliberate overload behavior.
