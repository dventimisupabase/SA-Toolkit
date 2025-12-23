# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Solutions Architect Toolkit - a collection of tools, scripts, and programs useful for Solutions Architects supporting PostgreSQL database products (primarily Supabase).

## Design Principles

- **Standard libpq authentication**: Use `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD` environment variables or `.pgpass`
- **Auto-detection over manual config**: Prefer querying the database for configuration (e.g., PG version) rather than requiring user input

## Tools

### batch-telemetry/sql/

Server-side batch telemetry for PostgreSQL 15, 16, or 17. Diagnoses batch job performance variance ("Why did this batch take 60 minutes instead of 10?").

**Requirements:** PostgreSQL 15+, pg_cron extension (1.4.1+ recommended for 30-second sampling)

**Installation:**
```bash
psql -f batch-telemetry/sql/install.sql
```

**Uninstall:**
```bash
psql -f batch-telemetry/sql/uninstall.sql
```

**Quick Start:**
```sql
-- 1. Track your target table(s)
SELECT telemetry.track_table('orders');

-- 2. Run your batch job, note start/end times

-- 3. Analyze
SELECT * FROM telemetry.compare('2024-12-16 14:00', '2024-12-16 15:00');
SELECT * FROM telemetry.table_compare('orders', '2024-12-16 14:00', '2024-12-16 15:00');
SELECT * FROM telemetry.wait_summary('2024-12-16 14:00', '2024-12-16 15:00');
```

**Two-Tier Collection (via pg_cron):**
- Snapshots (every 5 min): WAL, checkpoints, bgwriter, replication, temp files, I/O stats
- Samples (every 30 sec): wait events, active sessions, lock contention, operation progress

**Key Views:**
- `telemetry.deltas` - Snapshot deltas (checkpoint, WAL, buffer pressure, temp files)
- `telemetry.table_deltas` - Per-table deltas (size, tuples, vacuum activity)
- `telemetry.recent_locks` - Lock contention (last 2 hours)
- `telemetry.recent_waits` - Wait events (last 2 hours)
- `telemetry.recent_activity` - Active sessions (last 2 hours)
- `telemetry.recent_progress` - Vacuum/COPY/analyze progress (last 2 hours)
- `telemetry.recent_replication` - Replication lag (last 2 hours)

**Key Functions:**
- `telemetry.track_table(name, schema)` - Register table for monitoring
- `telemetry.compare(start, end)` - Compare system stats between time points
- `telemetry.table_compare(table, start, end)` - Compare table stats
- `telemetry.wait_summary(start, end)` - Aggregate wait events
- `telemetry.cleanup(interval)` - Remove old data (default: 7 days)

**Diagnostic Patterns:**
1. Lock contention - `recent_locks` shows blocked_pid entries
2. Buffer pressure - `bgw_buffers_backend_delta > 0`
3. Checkpoint interference - `checkpoint_occurred = true`
4. Autovacuum interference - `autovacuum_ran = true`
5. Temp file spills - `temp_files_delta > 0`
6. Replication lag - `recent_replication` shows high replay_lag

**PG Version Differences:**
- PG 15: Checkpoint stats in pg_stat_bgwriter, no pg_stat_io
- PG 16: Checkpoint stats in pg_stat_bgwriter, pg_stat_io available
- PG 17: Checkpoint stats in pg_stat_checkpointer, pg_stat_io available

### multi-region-ha/

Reference architecture for single-writer, multi-region disaster recovery for Supabase. Prioritizes data consistency over automatic failover (no split-brain).

**Architecture:** Single primary + warm standby with PgBouncer on Fly.io for stable connection endpoint and PostgreSQL logical replication for CDC.

**Requirements:** Two Supabase projects (Pro+), Fly.io account, PostgreSQL 15+, multi-region object storage

**Key Scripts:**
```bash
# Health checks
./multi-region-ha/scripts/health/check_primary_health.sh
./multi-region-ha/scripts/health/check_replication_lag.sh
./multi-region-ha/scripts/health/check_pgbouncer_health.sh

# Failover
./multi-region-ha/scripts/failover/failover.sh
./multi-region-ha/scripts/failover/failover.sh --skip-freeze  # Emergency
```

**Configuration:**
```bash
cp multi-region-ha/config/env.example multi-region-ha/config/.env
# Set: PRIMARY_HOST, STANDBY_HOST, POSTGRES_PASSWORD, FLY_APP_NAME
```

**RTO/RPO:**
- RPO: Seconds to minutes (replication lag dependent)
- RTO: 2-5 minutes (scripted) / 5-15 minutes (manual)

**Key Runbooks:**
- `runbooks/failover-runbook.md` - Full failover procedure
- `runbooks/failback-runbook.md` - Return to original primary
- `runbooks/emergency-runbook.md` - When primary is unreachable
- `runbooks/testing-runbook.md` - Practice and validation

### storage-to-s3/

One-time migration tool to move objects from Supabase Storage to AWS S3.

**Requirements:** Supabase CLI (linked to project), AWS CLI v2

**Quick Start:**
```bash
# 1. Link Supabase project
supabase link --project-ref <your-project-ref>

# 2. Configure
cp storage-to-s3/config/env.example storage-to-s3/config/.env
# Edit .env: AWS_S3_BUCKET, AWS_REGION, SUPABASE_BUCKETS

# 3. Preview
./storage-to-s3/scripts/migrate.sh --dry-run

# 4. Migrate
./storage-to-s3/scripts/migrate.sh

# 5. Verify
./storage-to-s3/scripts/verify.sh
```

**Key Scripts:**
- `scripts/migrate.sh` - Main migration (supports `--dry-run`, `--bucket NAME`)
- `scripts/verify.sh` - Compare object counts between Supabase and S3

**Configuration:**
- `SUPABASE_BUCKETS` - `"all"` or space-separated bucket names
- `AWS_S3_BUCKET` - Target S3 bucket
- `S3_PREFIX` - Optional prefix for migrated objects