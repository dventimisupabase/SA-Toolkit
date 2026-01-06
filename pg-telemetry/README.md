# pg-telemetry

Server-side performance telemetry for PostgreSQL. Continuously collects metrics to answer: "What was happening during this time window?"

## Why?

Managed PostgreSQL platforms (Supabase, RDS, Cloud SQL) don't allow custom extensions like [pg_wait_sampling](https://github.com/postgrespro/pg_wait_sampling). This tool provides similar Active Session History (ASH) functionality using only built-in PostgreSQL features.

**What it captures:**
- Wait events and active sessions (every 30 seconds)
- WAL, checkpoints, buffer stats (every 5 minutes)
- Lock contention and blocking queries
- Operation progress (vacuum, COPY, analyze, index creation)
- Replication lag history
- Per-table statistics for monitored tables

**Trade-offs:** Dedicated extensions are more efficient. Use pg-telemetry when you can't install extensions or need the additional metrics it provides (locks, progress, replication, I/O).

## Requirements

- PostgreSQL 15, 16, or 17
- `pg_cron` extension (1.4.1+ recommended for 30-second sampling)
- Superuser or appropriate privileges
- Supabase CLI (optional, for Supabase project workflow)

## Quick Start

### Local Development

```bash
# Start local Supabase
supabase start

# Apply migration
supabase db reset

# Run tests
supabase test db
```

### Deploy to Hosted Project

```bash
# Link to your project
supabase link --project-ref <your-project-ref>

# Push migration
supabase db push
```

## Usage

Once deployed, telemetry collects automatically via `pg_cron`:

```sql
-- View recent activity (rolling 2-hour window)
SELECT * FROM telemetry.recent_waits;
SELECT * FROM telemetry.recent_locks;
SELECT * FROM telemetry.recent_activity;

-- Compare system metrics between two time points
SELECT * FROM telemetry.compare('2024-12-16 14:00', '2024-12-16 15:00');

-- Automatic anomaly detection
SELECT * FROM telemetry.anomaly_report('2024-12-16 14:00', '2024-12-16 15:00');

-- Comprehensive diagnostic report
SELECT * FROM telemetry.summary_report('2024-12-16 14:00', '2024-12-16 15:00');
```

### Table Tracking

Track specific tables for detailed monitoring:

```sql
-- Register a table
SELECT telemetry.track_table('orders');

-- Compare table stats between time points
SELECT * FROM telemetry.table_compare('orders', '2024-12-16 14:00', '2024-12-16 15:00');
```

### Query Analysis (requires pg_stat_statements)

```sql
-- Compare query performance between time windows
SELECT * FROM telemetry.statement_compare('2024-12-16 14:00', '2024-12-16 15:00');
```

## How It Works

Telemetry uses `pg_cron` to run two types of collection:

1. **Snapshots** (every 5 minutes): Cumulative stats from `pg_stat_*` views (WAL, checkpoints, bgwriter, replication, temp files, I/O)
2. **Samples** (every 30 seconds): Point-in-time snapshots of wait events, active sessions, locks, and operation progress

Analysis functions compare snapshots or aggregate samples to diagnose performance issues.

## Key Functions

| Function | Purpose |
|----------|---------|
| `telemetry.compare(start, end)` | Compare system stats between time points |
| `telemetry.wait_summary(start, end)` | Aggregate wait events over time period |
| `telemetry.activity_at(timestamp)` | What was happening at specific moment? |
| `telemetry.anomaly_report(start, end)` | Automatic detection of 6 issue types |
| `telemetry.summary_report(start, end)` | Comprehensive diagnostic report |
| `telemetry.table_compare(table, start, end)` | Compare table stats |
| `telemetry.statement_compare(start, end)` | Compare query performance |

## Key Views

| View | Purpose |
|------|---------|
| `telemetry.recent_waits` | Wait events (last 2 hours) |
| `telemetry.recent_activity` | Active sessions (last 2 hours) |
| `telemetry.recent_locks` | Lock contention (last 2 hours) |
| `telemetry.recent_progress` | Operation progress (last 2 hours) |
| `telemetry.deltas` | Snapshot deltas (checkpoint, WAL, buffers) |

## Collection Modes

Reduce overhead on stressed systems:

| Mode | Sample Interval | Locks | Progress | Use Case |
|------|-----------------|-------|----------|----------|
| `normal` | 30 seconds | Yes | Yes | Default operation |
| `light` | 60 seconds | Yes | No | Moderate load |
| `emergency` | 120 seconds | No | No | System under severe stress |

```sql
-- Switch modes
SELECT telemetry.set_mode('emergency');

-- Check current mode
SELECT * FROM telemetry.get_mode();
```

## Anomaly Detection

Automatically detects 6 common issues:

| Anomaly Type | Description |
|--------------|-------------|
| `CHECKPOINT_DURING_WINDOW` | Checkpoint occurred (potential I/O spike) |
| `FORCED_CHECKPOINT` | WAL exceeded max_wal_size |
| `BUFFER_PRESSURE` | Backends writing directly (shared_buffers exhausted) |
| `BACKEND_FSYNC` | Backends doing fsync (bgwriter can't keep up) |
| `TEMP_FILE_SPILLS` | Queries spilling to disk (work_mem too low) |
| `LOCK_CONTENTION` | Sessions blocked waiting for locks |

```sql
SELECT anomaly_type, severity, description, recommendation
FROM telemetry.anomaly_report('2024-12-16 14:00', '2024-12-16 15:00');
```

## Project Structure

```
pg-telemetry/
├── supabase/
│   ├── config.toml              # Supabase configuration
│   ├── migrations/
│   │   ├── 20260105000000_enable_pg_cron.sql
│   │   └── 20260106000000_pg_telemetry.sql
│   └── tests/
│       └── 00001_telemetry_test.sql
├── install.sql                  # Standalone install (non-Supabase)
├── uninstall.sql                # Standalone uninstall
└── README.md
```

## Testing

The test suite uses [pgTAP](https://pgtap.org/) via `supabase test db`.

### Run Tests Locally

```bash
# Ensure local Supabase is running
supabase start

# Run all tests (67 tests)
supabase test db
```

### Test Coverage

| Category | Tests | Description |
|----------|-------|-------------|
| Installation Verification | 15 | Schema, tables, views, functions |
| Function Existence | 19 | All 19 functions present |
| Core Functionality | 10 | snapshot(), sample(), config |
| Table Tracking | 5 | track/untrack/list operations |
| Analysis Functions | 8 | compare(), wait_summary(), anomaly_report(), etc. |
| Configuration | 5 | get_mode(), set_mode() |
| Views | 5 | All views queryable |

## Standalone Installation (Non-Supabase)

For PostgreSQL without Supabase:

```bash
# Install
psql -f install.sql

# Uninstall
psql -f uninstall.sql
```

Requires PostgreSQL 15+ with pg_cron and superuser privileges.

## Important Notes

- Telemetry runs automatically after installation via `pg_cron`
- Default retention is 7 days (configurable via `telemetry.cleanup()`)
- If pg_cron < 1.4.1, sampling falls back to every minute instead of 30 seconds
- pg_stat_statements is optional but recommended for query analysis
- For stressed systems, use `telemetry.set_mode('emergency')` to reduce overhead
