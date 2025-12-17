# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Solutions Architect Toolkit - a collection of tools, scripts, and programs useful for Solutions Architects supporting PostgreSQL database products.

## Design Principles

- **Standard libpq authentication**: Use `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD` environment variables or `.pgpass`
- **Auto-detection over manual config**: Prefer querying the database for configuration (e.g., PG version) rather than requiring user input

## Tools

### batch-telemetry/sql/

Server-side batch telemetry for PostgreSQL 15, 16, or 17. Diagnoses batch job performance variance ("Why did this batch take 60 minutes instead of 10?").

**Requirements:** PostgreSQL 15+, pg_cron extension

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
- `telemetry.recent_locks` - Lock contention (last 2 hours)
- `telemetry.recent_waits` - Wait events (last 2 hours)
- `telemetry.recent_replication` - Replication lag (last 2 hours)

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
