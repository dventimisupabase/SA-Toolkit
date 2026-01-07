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

**⚠️ PERFORMANCE WARNING:** Each tracked table adds overhead to every snapshot (every 5 minutes):
- 3 size calculations (relation, indexes, total) per table
- 1 JOIN to pg_stat_user_tables per table
- On slow storage or large tables (>10GB), can add 10-50ms per table

**Recommendation:** Track only critical tables (5-20 tables max). Avoid tracking:
- Very large tables (>100GB) unless absolutely necessary
- Tables with heavy concurrent access
- Temporary or frequently dropped tables

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

### Kill Switch

For real emergencies, completely stop all telemetry collection:

```sql
-- Stop all collection immediately (unschedules all cron jobs)
SELECT telemetry.disable();

-- Restart collection when crisis is over
SELECT telemetry.enable();
```

**What it does:**
- `disable()` - Unschedules all 3 cron jobs, stops collection completely
- `enable()` - Re-schedules jobs based on current mode setting

## Safety Features

pg-telemetry includes P0 production safety mechanisms to prevent the observer from becoming part of the problem:

### 1. Statement & Lock Timeouts

Collection functions have built-in timeouts to prevent hanging:
- **Statement timeout**: 5 seconds (entire function must complete)
- **Lock timeout**: 1 second (max wait for locks)

If a collection query hangs due to contended system catalogs, it will be automatically terminated rather than consuming resources indefinitely.

### 2. Graceful Degradation

Each collection section is wrapped in exception handlers. If one part fails, the rest continues:
- Wait events fail → Activity samples still collected
- Lock detection fails → Progress tracking still works
- Partial data is better than no data during incidents

Failures generate PostgreSQL warnings visible in logs but don't abort the entire collection.

### 3. Circuit Breaker

Automatic protection against slow or stuck collectors:

```sql
-- View circuit breaker status and collection performance
SELECT collection_type, started_at, duration_ms, success, skipped
FROM telemetry.collection_stats
ORDER BY started_at DESC
LIMIT 20;
```

**How it works:**
- If any collection takes >5 seconds (configurable), next run is automatically skipped
- Prevents cascading failures when system is stressed
- Auto-resumes after 5 minutes if system recovers
- Skipped collections are logged with reason

**Configuration:**
```sql
-- Adjust threshold (milliseconds)
UPDATE telemetry.config SET value = '10000' WHERE key = 'circuit_breaker_threshold_ms';

-- Disable circuit breaker (not recommended for production)
UPDATE telemetry.config SET value = 'false' WHERE key = 'circuit_breaker_enabled';
```

### 4. Limited Result Sets

Safety limits on expensive queries:
- Lock detection: Top 100 blocking relationships (prevents O(n²) explosion)
- Active sessions: Top 25 (prevents excessive row capture)
- pg_stat_statements: Top 50 queries (configurable)

### 5. Schema Size Monitoring (P1)

Automatic monitoring and enforcement of telemetry schema size limits:

```sql
-- Check current schema size and status
SELECT * FROM telemetry._check_schema_size();
```

**How it works:**
- Checks schema size on every sample/snapshot collection
- **Warning threshold** (default 5GB): Logs warning, continues collection
- **Critical threshold** (default 10GB): Automatically disables collection
- Prevents unbounded growth that could impact database performance

**Configuration:**
```sql
-- Adjust thresholds (megabytes)
UPDATE telemetry.config SET value = '8000' WHERE key = 'schema_size_warning_mb';
UPDATE telemetry.config SET value = '15000' WHERE key = 'schema_size_critical_mb';

-- Disable monitoring (not recommended)
UPDATE telemetry.config SET value = 'false' WHERE key = 'schema_size_check_enabled';
```

### 6. Optimized pg_stat_io Collection (P1)

Reduced overhead for PostgreSQL 16+ I/O statistics:
- Single query with `FILTER` clauses instead of 4 separate queries
- 4× fewer catalog lookups
- Consistent snapshot across all backend types
- Lower probability of race conditions

### 7. Post-Cleanup VACUUM (P1)

Automatic space reclamation after data deletion:

```sql
-- Cleanup now returns vacuum results
SELECT * FROM telemetry.cleanup('7 days');
-- Returns: deleted_snapshots, deleted_samples, vacuumed_tables
```

**What it does:**
- Runs `VACUUM ANALYZE` on all telemetry tables after cleanup
- Reclaims disk space from deleted rows
- Updates query planner statistics
- Prevents table bloat over time
- Each table vacuumed independently with exception handling

### 8. Automatic Mode Switching (P2)

Monitors system health and auto-adjusts collection mode based on load indicators:

```sql
-- Enable automatic mode switching
UPDATE telemetry.config SET value = 'true' WHERE key = 'auto_mode_enabled';

-- Configure thresholds
UPDATE telemetry.config SET value = '80' WHERE key = 'auto_mode_connections_threshold';
UPDATE telemetry.config SET value = '3' WHERE key = 'auto_mode_trips_threshold';
```

**How it works:**
- Checks system indicators every sample collection (30s-2min depending on mode)
- **Normal → Light**: When active connections ≥80% of max_connections
- **Light/Normal → Emergency**: When circuit breaker trips ≥3 times in 10 minutes
- **Emergency → Light**: When no circuit breaker trips for 10 minutes
- **Light → Normal**: When connections drop below 70% of threshold
- Mode changes logged via PostgreSQL NOTICE

**Why use it:**
- Reduces telemetry overhead automatically during high load
- Prevents telemetry from contributing to cascading failures
- Auto-recovers to normal monitoring when system stabilizes

### 9. Configurable Retention by Table Type (P2)

Different retention periods for different data types:

```sql
-- Configure retention (days)
UPDATE telemetry.config SET value = '7' WHERE key = 'retention_samples_days';      -- High frequency
UPDATE telemetry.config SET value = '30' WHERE key = 'retention_snapshots_days';   -- Cumulative stats
UPDATE telemetry.config SET value = '30' WHERE key = 'retention_statements_days';  -- Query stats

-- Cleanup uses configured retention (new default behavior)
SELECT * FROM telemetry.cleanup();
-- Returns: deleted_snapshots, deleted_samples, deleted_statements, vacuumed_tables

-- Legacy: Specify retention explicitly (overrides config)
SELECT * FROM telemetry.cleanup('7 days');
```

**Benefits:**
- Keep cumulative stats longer than high-frequency samples
- Balance disk usage with diagnostic capabilities
- Samples (every 30s) default to 7 days, snapshots (every 5min) default to 30 days

### 10. Partition Management Helpers (P2)

Optional functions for time-based partitioning (advanced use case):

```sql
-- Check current partition status
SELECT * FROM telemetry.partition_status();

-- Create next partition (if using partitioned tables)
SELECT telemetry.create_next_partition('samples', 'day');
SELECT telemetry.create_next_partition('snapshots', 'week');

-- Drop old partitions (faster than DELETE)
SELECT * FROM telemetry.drop_old_partitions('samples', '7 days');
```

**When to use:**
- Very high volume installations (thousands of samples/day)
- Need faster cleanup operations (DROP PARTITION vs DELETE)
- Want partition-level backup/restore capabilities

**Note:** Converting existing tables to partitioned requires data migration. These functions are for new installs or users who have already migrated to partitioned tables.

### 11. Health Checks and Self-Monitoring (P3)

Operational visibility into the telemetry system itself:

```sql
-- Quick health status of all telemetry components
SELECT * FROM telemetry.health_check();
-- Returns: component, status, details, action_required

-- Analyze telemetry performance impact over time
SELECT * FROM telemetry.performance_report('24 hours');
-- Returns: metric, value, assessment
```

**Components monitored:**
- **Telemetry System**: Enabled/disabled status, current mode
- **Schema Size**: Current size vs thresholds with percentage
- **Circuit Breaker**: Recent trips in last hour
- **Collection Freshness**: When last sample/snapshot was collected
- **Data Volume**: Current counts of samples and snapshots

**Performance metrics:**
- Avg/Max sample duration (with assessment: Excellent/Good/Acceptable/Poor)
- Avg snapshot duration
- Schema size with cleanup recommendations
- Collection success rate
- Skipped collection count

**Use cases:**
- Operational dashboards: Monitor telemetry health
- Troubleshooting: Identify when telemetry stops collecting
- Capacity planning: Track growth rates and performance trends

### 12. Alert System (P4)

Proactive notifications for critical conditions:

```sql
-- Enable alerts
UPDATE telemetry.config SET value = 'true' WHERE key = 'alert_enabled';

-- Configure thresholds
UPDATE telemetry.config SET value = '5' WHERE key = 'alert_circuit_breaker_count';  -- 5 trips/hour
UPDATE telemetry.config SET value = '8000' WHERE key = 'alert_schema_size_mb';      -- 8GB warning

-- Check for active alerts
SELECT * FROM telemetry.check_alerts('1 hour');
-- Returns: alert_type, severity, message, triggered_at, recommendation
```

**Alert types:**
- **CIRCUIT_BREAKER_TRIPS** (CRITICAL): Excessive trips indicate system stress
- **SCHEMA_SIZE_HIGH** (WARNING): Schema approaching critical threshold
- **COLLECTION_FAILURES** (WARNING): Multiple collection failures detected
- **STALE_DATA** (CRITICAL): No recent collections (possible pg_cron failure)

**Integration:**
- Poll `check_alerts()` from external monitoring (Datadog, PagerDuty, etc.)
- Schedule via pg_cron to log alerts to application_name
- Disabled by default to avoid alert fatigue

### 13. Data Export and Integration (P4)

Export telemetry data for external analysis:

```sql
-- Export to JSON for external tools
SELECT telemetry.export_json(
    '2024-12-16 14:00'::timestamptz,
    '2024-12-16 15:00'::timestamptz,
    true,  -- include_samples
    true   -- include_snapshots
);
-- Returns: JSONB with export_time, start_time, end_time, samples[], snapshots[]
```

**Use cases:**
- Export to time-series databases (InfluxDB, Prometheus)
- Import to data warehouses for long-term analysis
- Share incident data with support teams
- Integrate with custom visualization tools

**JSON structure:**
```json
{
  "export_time": "2024-12-16T15:30:00Z",
  "start_time": "2024-12-16T14:00:00Z",
  "end_time": "2024-12-16T15:00:00Z",
  "samples": [
    {
      "captured_at": "...",
      "wait_events": [...],
      "locks": [...]
    }
  ],
  "snapshots": [...]
}
```

### 14. Configuration Recommendations (P4)

AI-assisted configuration optimization:

```sql
-- Get personalized recommendations based on actual usage
SELECT * FROM telemetry.config_recommendations();
-- Returns: category, recommendation, reason, sql_command
```

**Recommendation categories:**
- **Performance**: Mode optimization based on sample duration
- **Storage**: Cleanup and retention tuning based on volume
- **Automation**: Auto-mode suggestions when overhead varies
- **Scalability**: Partitioning recommendations for high volume

**Example output:**
```
category     | recommendation                  | reason                           | sql_command
-------------|---------------------------------|----------------------------------|---------------------------
Performance  | Switch to light mode            | Average sample duration is 1200ms| SELECT telemetry.set_mode('light');
Storage      | Run cleanup to reclaim space    | Schema size is 6500 MB           | SELECT * FROM telemetry.cleanup();
Automation   | Enable automatic mode switching | Sample duration varies           | UPDATE telemetry.config SET...
```

**When to use:**
- After initial deployment (baseline configuration)
- During capacity planning exercises
- When investigating performance issues
- Quarterly optimization reviews

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

# Run all tests (127 tests)
supabase test db
```

**Note:** Tests run inside a transaction, so VACUUM warnings are expected during `cleanup()` tests. In production, cleanup runs via pg_cron outside transactions and VACUUM works normally.

### Test Coverage

| Category | Tests | Description |
|----------|-------|-------------|
| Installation Verification | 16 | Schema, 12 tables, 7 views |
| Function Existence | 24 | All functions including P0/P1/P2/P3/P4 helpers |
| Core Functionality | 10 | snapshot(), sample(), config |
| Table Tracking | 5 | track/untrack/list operations |
| Analysis Functions | 8 | compare(), wait_summary(), anomaly_report(), etc. |
| Configuration | 5 | get_mode(), set_mode() |
| Views | 5 | All views queryable |
| Kill Switch | 6 | disable(), enable() |
| P0 Safety Features | 10 | Circuit breaker, exception handling, stats tracking |
| P1 Safety Features | 8 | Schema size monitoring, optimized queries, post-cleanup VACUUM |
| P2 Safety Features | 12 | Auto mode switching, configurable retention, partition helpers |
| P3 Operational Features | 9 | Health checks, performance reports, self-monitoring |
| P4 Advanced Features | 10 | Alerts, JSON export, configuration recommendations |

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
