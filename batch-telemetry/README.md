# Batch Telemetry for PostgreSQL

Server-side telemetry for diagnosing batch job performance variance. Answers: "Why did this batch take 60 minutes instead of 10?"

## Overview

When batch jobs exhibit variance (e.g., usually 10 minutes but sometimes 60 minutes), you need telemetry to understand what happened. This tool automatically collects performance metrics via `pg_cron` and provides analysis functions to compare time windows.

## Requirements

- PostgreSQL 15, 16, or 17
- `pg_cron` extension (1.4.1+ recommended for 30-second sampling)
- Superuser or appropriate privileges to create schema/functions

## Quick Start

```bash
# Install
psql -f sql/install.sql

# Uninstall
psql -f sql/uninstall.sql
```

```sql
-- 1. Track your target table(s) before running the batch
SELECT telemetry.track_table('orders');

-- 2. Run your batch job, note the start/end times
--    (telemetry collects automatically in the background)

-- 3. Analyze the batch window
SELECT * FROM telemetry.compare('2024-12-16 14:00', '2024-12-16 15:00');
SELECT * FROM telemetry.table_compare('orders', '2024-12-16 14:00', '2024-12-16 15:00');
SELECT * FROM telemetry.wait_summary('2024-12-16 14:00', '2024-12-16 15:00');
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

### Samples (every 30 sec)

Point-in-time snapshots for real-time visibility:
- **Wait events**: aggregated by backend_type, wait_event_type, wait_event
- **Active sessions**: top 25 non-idle sessions with query preview
- **Operation progress**: vacuum, COPY, analyze, create index
- **Lock contention**: blocked/blocking PIDs with queries

## Key Functions

| Function | Purpose |
|----------|---------|
| `telemetry.track_table(name, schema)` | Register a table for monitoring |
| `telemetry.untrack_table(name, schema)` | Stop monitoring a table |
| `telemetry.list_tracked_tables()` | Show all tracked tables |
| `telemetry.compare(start, end)` | Compare system stats between time points |
| `telemetry.table_compare(table, start, end)` | Compare table stats between time points |
| `telemetry.wait_summary(start, end)` | Aggregate wait events over a time period |
| `telemetry.cleanup(interval)` | Remove old data (default: retain 7 days) |
| `telemetry.snapshot()` | Manual snapshot capture |
| `telemetry.sample()` | Manual sample capture |

## Key Views

| View | Purpose |
|------|---------|
| `telemetry.deltas` | Snapshot deltas (checkpoint, WAL, buffers, temp files) |
| `telemetry.table_deltas` | Per-table deltas (size, tuples, vacuum) |
| `telemetry.recent_waits` | Wait events (last 2 hours) |
| `telemetry.recent_activity` | Active sessions (last 2 hours) |
| `telemetry.recent_locks` | Lock contention (last 2 hours) |
| `telemetry.recent_progress` | Vacuum/COPY/analyze progress (last 2 hours) |
| `telemetry.recent_replication` | Replication lag (last 2 hours) |

## Diagnostic Patterns

### Pattern 1: Lock Contention

**Symptoms:**
- Batch takes 10x longer than expected
- `telemetry.recent_locks` shows `blocked_pid` entries
- `wait_summary()` shows Lock:relation or Lock:extend events

```sql
SELECT * FROM telemetry.recent_locks
WHERE captured_at BETWEEN '2024-12-16 14:00' AND '2024-12-16 15:00';
```

**Resolution:** Identify blocking query, consider table partitioning, shorter transactions, or scheduling.

### Pattern 2: Buffer/WAL Pressure

**Symptoms:**
- Batch takes 10-20x longer than baseline
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
- High `ckpt_write_time_ms` during batch window
- `ckpt_requested_delta > 0` (WAL exceeded max_wal_size)

**Resolution:** Increase `max_wal_size`, schedule batches after `checkpoint_timeout`.

### Pattern 4: Autovacuum Interference

**Symptoms:**
- `table_compare()` shows `autovacuum_ran = true` during batch
- `recent_progress` shows vacuum phases overlapping batch
- Wait events: `LWLock:BufferContent`, `IO:DataFileRead`

**Resolution:** Schedule batches to avoid autovacuum, temporarily disable with `ALTER TABLE ... SET (autovacuum_enabled = false)`, or increase `autovacuum_vacuum_cost_delay`.

### Pattern 5: Temp File Spills

**Symptoms:**
- Batch with complex queries runs slowly
- `compare()` shows `temp_files_delta > 0`
- Large `temp_bytes_delta` (hundreds of MB or GB)

```sql
SELECT temp_files_delta, temp_bytes_pretty
FROM telemetry.compare('2024-12-16 14:00', '2024-12-16 15:00');
```

**Resolution:** Increase `work_mem` for the session: `SET work_mem = '256MB';`

### Pattern 6: Replication Lag

**Symptoms:**
- Batch runs slowly despite no local resource contention
- `recent_replication` shows large `replay_lag_bytes`
- `write_lag`/`flush_lag` intervals in seconds or more

```sql
SELECT * FROM telemetry.recent_replication
WHERE captured_at BETWEEN '2024-12-16 14:00' AND '2024-12-16 15:00';
```

**Resolution:** Check replica health, consider asynchronous replication, or use `SET LOCAL synchronous_commit = off;` within batch transaction.

## Quick Diagnosis Checklist

For a slow batch between `START` and `END`:

```sql
-- 1. Overall health
SELECT * FROM telemetry.compare('START', 'END');

-- 2. Lock contention
SELECT * FROM telemetry.recent_locks
WHERE captured_at BETWEEN 'START' AND 'END';

-- 3. Wait events
SELECT * FROM telemetry.wait_summary('START', 'END');

-- 4. Table-specific (if tracking)
SELECT * FROM telemetry.table_compare('mytable', 'START', 'END');

-- 5. Active operations
SELECT * FROM telemetry.recent_progress
WHERE captured_at BETWEEN 'START' AND 'END';

-- 6. Replication lag
SELECT * FROM telemetry.recent_replication
WHERE captured_at BETWEEN 'START' AND 'END';
```

## Interpreting Results

### Checkpoint Pressure
- `checkpoint_occurred=true` with large `ckpt_write_time_ms` => checkpoint during batch
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
batch-telemetry/
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
