# pg-telemetry: PostgreSQL Performance Telemetry

Server-side telemetry for PostgreSQL performance diagnostics. Continuously collects metrics to answer: "What was happening during this time window?"

## Overview

This tool automatically collects performance metrics via `pg_cron` and provides analysis functions to diagnose performance issues. Use it for:

- **Ongoing monitoring** - rolling 2-hour views of wait events, locks, and activity
- **Time-window analysis** - compare any two points in time to see what changed
- **Batch job diagnostics** - understand why a job took longer than expected
- **Capacity planning** - track WAL growth, buffer pressure, replication lag trends
- **Incident investigation** - historical data to reconstruct what happened

## Why this tool?

PostgreSQL has excellent extensions for performance monitoring like [pg_wait_sampling](https://github.com/postgrespro/pg_wait_sampling) that provide Active Session History (ASH) functionality with efficient kernel-level sampling. However:

- **Managed platforms restrict extensions** - Supabase, Amazon RDS, Google Cloud SQL, and Azure Database for PostgreSQL don't allow arbitrary extension installation
- **pg_wait_sampling isn't universally available** - even when extensions are allowed, pg_wait_sampling may not be in the approved list

This tool provides ASH-like functionality using **only built-in PostgreSQL features**:

| Feature | pg_wait_sampling | pg-telemetry |
|---------|------------------|--------------|
| Wait event sampling | Yes (efficient, in-process) | Yes (via pg_stat_activity polling) |
| Active session history | Yes | Yes |
| Lock contention tracking | No | Yes |
| Operation progress | No | Yes (vacuum, COPY, analyze, index) |
| Replication lag history | No | Yes |
| Checkpoint/WAL/I/O stats | No | Yes |
| Custom extension required | Yes | No |
| Works on Supabase | No | Yes |
| Works on RDS/Cloud SQL | Maybe (check availability) | Yes |
| Sampling overhead | Very low | Low (SQL-based polling) |

**Trade-offs:** Dedicated extensions like pg_wait_sampling are more efficient (lower overhead, finer granularity). Use them when available. Use pg-telemetry when you can't install extensions or need the additional metrics it provides (locks, progress, replication, I/O).

## Requirements

- PostgreSQL 15, 16, or 17
- `pg_cron` extension (1.4.1+ recommended for 30-second sampling)
- Superuser or appropriate privileges to create schema/functions
- Supabase CLI (optional, for Supabase project workflow)

## Deployment Methods

### Option 1: Supabase Project (Recommended)

Use the Supabase CLI for local testing with pgTAP tests and easy deployment:

```bash
# Local development
supabase start          # Start local Supabase
supabase db reset       # Apply migration
supabase test db        # Run 67 pgTAP tests

# Deploy to hosted project
supabase link --project-ref <your-project-ref>
supabase db push
```

### Option 2: Standalone Installation

Direct installation on any PostgreSQL 15+ with pg_cron:

```bash
# Install
psql -f install.sql

# Uninstall
psql -f uninstall.sql
```

```sql
-- Telemetry collects automatically after installation

-- View recent activity (rolling 2-hour window)
SELECT * FROM telemetry.recent_waits;
SELECT * FROM telemetry.recent_locks;
SELECT * FROM telemetry.recent_activity;

-- Analyze a specific time window
SELECT * FROM telemetry.compare('2024-12-16 14:00', '2024-12-16 15:00');
SELECT * FROM telemetry.wait_summary('2024-12-16 14:00', '2024-12-16 15:00');

-- Optionally track specific tables for detailed monitoring
SELECT telemetry.track_table('orders');
SELECT * FROM telemetry.table_compare('orders', '2024-12-16 14:00', '2024-12-16 15:00');
```

## Two-Tier Collection

Telemetry runs automatically via `pg_cron`:

| Tier | Interval | What's Captured |
|------|----------|-----------------|
| Snapshots | 5 minutes | WAL, checkpoints, bgwriter, replication, temp files, I/O |
| Samples | 30 seconds | Wait events, active sessions, locks, operation progress |

### Snapshots (every 5 min)

Cumulative stats meaningful as deltas:
- **WAL**: bytes generated, write/sync time
- **Checkpoints**: timed/requested count, write/sync time, buffers
- **BGWriter**: buffers clean/alloc/backend (backend writes = pressure)
- **Replication slots**: count, max retained WAL bytes
- **Replication lag**: per-replica write_lag, flush_lag, replay_lag
- **Temp files**: cumulative temp files and bytes (work_mem spills)
- **pg_stat_io** (PG16+): I/O by backend type
- **Per-table stats** for tracked tables: size, tuples, vacuum activity
- **pg_stat_statements** (if available): top 50 queries by execution time

### Samples (every 30 sec)

Point-in-time snapshots for real-time visibility:
- **Wait events**: aggregated by backend_type, wait_event_type, wait_event
- **Active sessions**: top 25 non-idle sessions with query preview
- **Operation progress**: vacuum, COPY, analyze, create index
- **Lock contention**: blocked/blocking PIDs with queries

## Key Functions

### Analysis Functions

| Function | Purpose |
|----------|---------|
| `telemetry.compare(start, end)` | Compare system stats between time points |
| `telemetry.wait_summary(start, end)` | Aggregate wait events over a time period |
| `telemetry.table_compare(table, start, end)` | Compare table stats between time points |
| `telemetry.statement_compare(start, end)` | Compare query stats (requires pg_stat_statements) |
| `telemetry.activity_at(timestamp)` | What was happening at a specific moment? |
| `telemetry.anomaly_report(start, end)` | Automatic detection of performance issues |
| `telemetry.summary_report(start, end)` | Comprehensive diagnostic report |

### Table Tracking

| Function | Purpose |
|----------|---------|
| `telemetry.track_table(name, schema)` | Register a table for monitoring |
| `telemetry.untrack_table(name, schema)` | Stop monitoring a table |
| `telemetry.list_tracked_tables()` | Show all tracked tables |

### Operations

| Function | Purpose |
|----------|---------|
| `telemetry.snapshot()` | Manual snapshot capture |
| `telemetry.sample()` | Manual sample capture |
| `telemetry.cleanup(interval)` | Remove old data (default: retain 7 days) |
| `telemetry.set_mode(mode)` | Switch collection mode (normal/light/emergency) |
| `telemetry.get_mode()` | Show current mode and settings |

## Key Views

| View | Purpose |
|------|---------|
| `telemetry.recent_waits` | Wait events (last 2 hours) |
| `telemetry.recent_activity` | Active sessions (last 2 hours) |
| `telemetry.recent_locks` | Lock contention (last 2 hours) |
| `telemetry.recent_progress` | Vacuum/COPY/analyze progress (last 2 hours) |
| `telemetry.recent_replication` | Replication lag (last 2 hours) |
| `telemetry.deltas` | Snapshot deltas (checkpoint, WAL, buffers, temp files) |
| `telemetry.table_deltas` | Per-table deltas (size, tuples, vacuum) |

## Diagnostic Patterns

### Pattern 1: Lock Contention

**Symptoms:**
- Queries taking much longer than expected
- `telemetry.recent_locks` shows `blocked_pid` entries
- `wait_summary()` shows Lock:relation or Lock:extend events

```sql
SELECT * FROM telemetry.recent_locks
WHERE captured_at BETWEEN '2024-12-16 14:00' AND '2024-12-16 15:00';
```

**Resolution:** Identify blocking query, consider table partitioning, shorter transactions, or scheduling.

### Pattern 2: Buffer/WAL Pressure

**Symptoms:**
- Write-heavy workloads running slower than expected
- `bgw_buffers_backend_delta > 0` (backends forced to write directly)
- High `wal_bytes_delta` relative to data volume
- Wait events: `LWLock:WALWrite`, `Lock:extend`

```sql
SELECT bgw_buffers_backend_delta, wal_bytes_pretty
FROM telemetry.compare('2024-12-16 14:00', '2024-12-16 15:00');
```

**Resolution:** Reduce concurrent writers, increase `shared_buffers` or `wal_buffers`, consider faster storage.

### Pattern 3: Checkpoint Interference

**Symptoms:**
- `compare()` shows `checkpoint_occurred = true`
- High `ckpt_write_time_ms` during the time window
- `ckpt_requested_delta > 0` (WAL exceeded max_wal_size)

**Resolution:** Increase `max_wal_size`, schedule heavy writes after `checkpoint_timeout`.

### Pattern 4: Autovacuum Interference

**Symptoms:**
- `table_compare()` shows `autovacuum_ran = true`
- `recent_progress` shows vacuum phases overlapping your workload
- Wait events: `LWLock:BufferContent`, `IO:DataFileRead`

**Resolution:** Schedule heavy writes to avoid autovacuum, temporarily disable with `ALTER TABLE ... SET (autovacuum_enabled = false)`, or increase `autovacuum_vacuum_cost_delay`.

### Pattern 5: Temp File Spills

**Symptoms:**
- Complex queries (JOINs, sorts, aggregations) running slowly
- `compare()` shows `temp_files_delta > 0`
- Large `temp_bytes_delta` (hundreds of MB or GB)

```sql
SELECT temp_files_delta, temp_bytes_pretty
FROM telemetry.compare('2024-12-16 14:00', '2024-12-16 15:00');
```

**Resolution:** Increase `work_mem` for the session: `SET work_mem = '256MB';`

### Pattern 6: Replication Lag

**Symptoms:**
- Writes slow despite no local resource contention
- `recent_replication` shows large `replay_lag_bytes`
- `write_lag`/`flush_lag` intervals in seconds or more

```sql
SELECT * FROM telemetry.recent_replication
WHERE captured_at BETWEEN '2024-12-16 14:00' AND '2024-12-16 15:00';
```

**Resolution:** Check replica health, consider asynchronous replication, or use `SET LOCAL synchronous_commit = off;`.

## Quick Diagnosis Checklist

For investigating a slow time window between `START` and `END`:

```sql
-- 1. Automatic anomaly detection (start here!)
SELECT * FROM telemetry.anomaly_report('START', 'END');

-- 2. Comprehensive summary
SELECT * FROM telemetry.summary_report('START', 'END');

-- 3. Which queries consumed the most time?
SELECT * FROM telemetry.statement_compare('START', 'END');

-- 4. Overall system health
SELECT * FROM telemetry.compare('START', 'END');

-- 5. Wait events breakdown
SELECT * FROM telemetry.wait_summary('START', 'END');

-- 6. Lock contention
SELECT * FROM telemetry.recent_locks
WHERE captured_at BETWEEN 'START' AND 'END';

-- 7. Table-specific (if tracking)
SELECT * FROM telemetry.table_compare('mytable', 'START', 'END');
```

### What was happening at a specific moment?

```sql
-- Find the nearest sample to a timestamp
SELECT * FROM telemetry.activity_at('2024-12-16 14:05:30');
```

Returns: active sessions, waiting sessions, top 3 wait events, blocked PIDs, running vacuums/copies/indexes, and whether a checkpoint occurred nearby.

## Interpreting Results

### Checkpoint Pressure
- `checkpoint_occurred=true` with large `ckpt_write_time_ms` => checkpoint during window
- `ckpt_requested_delta > 0` => forced checkpoint (WAL exceeded max_wal_size)

### WAL Pressure
- Large `wal_sync_time_ms` => WAL fsync bottleneck
- Compare `wal_bytes_delta` to expected (row_count * avg_row_size)

### Shared Buffer Pressure (PG15/16)
- `bgw_buffers_backend_delta > 0` => backends writing directly (bad)
- `bgw_buffers_backend_fsync_delta > 0` => backends doing fsync (very bad)

### I/O Contention (PG16+)
- High `io_checkpointer_write_time` => checkpoint I/O pressure
- High `io_autovacuum_writes` => vacuum competing for I/O bandwidth
- High `io_client_writes` => shared_buffers exhaustion

### Wait Event Red Flags
- `LWLock:BufferContent` => buffer contention
- `IO:DataFileRead/Write` => disk I/O bottleneck
- `Lock:transactionid` => row-level lock contention
- `Lock:relation` or `Lock:extend` => table-level lock contention

## pg_stat_statements Integration

If `pg_stat_statements` is installed, telemetry automatically captures the top 50 queries by total execution time with each snapshot. This enables:

```sql
-- Compare query performance between two time windows
SELECT queryid, query_preview,
       calls_delta,
       total_exec_time_delta_ms,
       time_per_call_ms,
       hit_ratio_pct
FROM telemetry.statement_compare('2024-12-16 14:00', '2024-12-16 15:00')
ORDER BY total_exec_time_delta_ms DESC;
```

**Columns returned:**
- `calls_delta` - Number of executions in the window
- `total_exec_time_delta_ms` - Total CPU time consumed
- `time_per_call_ms` - Average time per execution
- `hit_ratio_pct` - Buffer cache hit ratio (higher = better)
- `temp_blks_written_delta` - Temp file usage (work_mem spills)
- `wal_bytes_delta` - WAL generated by this query

**Configuration:**
```sql
-- Disable statement capture (if causing overhead)
UPDATE telemetry.config SET value = 'false' WHERE key = 'statements_enabled';

-- Change number of queries captured (default: 50)
UPDATE telemetry.config SET value = '100' WHERE key = 'statements_top_n';
```

## Collection Modes

For systems under stress, reduce telemetry overhead by switching modes:

| Mode | Sample Interval | Locks | Progress | Use Case |
|------|-----------------|-------|----------|----------|
| `normal` | 30 seconds | Yes | Yes | Default operation |
| `light` | 60 seconds | Yes | No | Moderate load |
| `emergency` | 120 seconds | No | No | System under severe stress |

```sql
-- Switch to emergency mode on stressed system
SELECT telemetry.set_mode('emergency');

-- Check current mode
SELECT * FROM telemetry.get_mode();

-- Return to normal after incident
SELECT telemetry.set_mode('normal');
```

**What each mode disables:**
- `light`: Disables vacuum/COPY/analyze progress tracking (saves queries to pg_stat_progress_* views)
- `emergency`: Also disables lock sampling (saves queries to pg_locks and pg_stat_activity joins)

## Anomaly Detection

The `anomaly_report()` function automatically detects common issues:

| Anomaly Type | Severity | What It Means |
|--------------|----------|---------------|
| `CHECKPOINT_DURING_WINDOW` | medium | A checkpoint occurred (potential I/O spike) |
| `FORCED_CHECKPOINT` | high | WAL exceeded max_wal_size, forced checkpoint |
| `BUFFER_PRESSURE` | high | Backends writing directly to disk (shared_buffers exhausted) |
| `BACKEND_FSYNC` | high | Backends doing fsync (very bad, bgwriter can't keep up) |
| `TEMP_FILE_SPILLS` | medium | Queries spilling to disk (work_mem too low) |
| `LOCK_CONTENTION` | medium | Sessions blocked waiting for locks |

```sql
-- Get all detected anomalies with recommendations
SELECT anomaly_type, severity, description, recommendation
FROM telemetry.anomaly_report('2024-12-16 14:00', '2024-12-16 15:00')
ORDER BY severity DESC;
```

## PG Version Differences

| Version | Checkpoint Stats | pg_stat_io |
|---------|------------------|------------|
| PG 15 | `pg_stat_bgwriter` | No |
| PG 16 | `pg_stat_bgwriter` | Yes |
| PG 17 | `pg_stat_checkpointer` | Yes |

## Scheduled Jobs (pg_cron)

| Job | Schedule | Purpose |
|-----|----------|---------|
| `telemetry_snapshot` | `*/5 * * * *` | Every 5 minutes |
| `telemetry_sample` | `30 seconds` | Every 30 seconds (if pg_cron 1.4.1+) |
| `telemetry_cleanup` | `0 3 * * *` | Daily at 3 AM, retains 7 days |

**Note:** The installer auto-detects pg_cron version. If < 1.4.1, it falls back to minute-level sampling and logs a notice.

## Directory Structure

```
pg-telemetry/
├── README.md           # This file
└── sql/
    ├── install.sql     # Installation script
    └── uninstall.sql   # Uninstallation script
```

## Manual Operation

If `pg_cron` is not available, run snapshots and samples manually:

```sql
-- Capture a snapshot
SELECT telemetry.snapshot();

-- Capture a sample
SELECT telemetry.sample();

-- Clean up old data (retain last 7 days)
SELECT * FROM telemetry.cleanup('7 days');
```
