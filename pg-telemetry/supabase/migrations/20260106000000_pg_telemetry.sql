-- =============================================================================
-- pg-telemetry: PostgreSQL Performance Telemetry
-- =============================================================================
--
-- Server-side telemetry for PostgreSQL performance diagnostics.
-- Continuously collects metrics to answer: "What was happening during this time window?"
--
-- REQUIREMENTS
-- ------------
--   - PostgreSQL 15, 16, or 17
--   - pg_cron extension (1.4.1+ recommended for 30-second sampling)
--   - Superuser or appropriate privileges to create schema/functions
--
-- INSTALLATION
-- ------------
--   psql -f install.sql
--
-- TWO-TIER COLLECTION
-- -------------------
--   1. Snapshots (every 5 min via pg_cron)
--      Cumulative stats that are meaningful as deltas:
--      - WAL: bytes generated, write/sync time
--      - Checkpoints: timed/requested count, write/sync time, buffers
--      - BGWriter: buffers clean/alloc/backend (backend writes = pressure)
--      - Replication slots: count, max retained WAL bytes
--      - Replication lag: per-replica write_lag, flush_lag, replay_lag
--      - Temp files: cumulative temp files and bytes (work_mem spills)
--      - pg_stat_io (PG16+): I/O by backend type
--      - Per-table stats for tracked tables: size, tuples, vacuum activity
--
--   2. Samples (every 30 sec via pg_cron)
--      Point-in-time snapshots for real-time visibility:
--      - Wait events: aggregated by backend_type, wait_event_type, wait_event
--      - Active sessions: top 25 non-idle sessions with query preview
--      - Operation progress: vacuum, COPY, analyze, create index
--      - Lock contention: blocked/blocking PIDs with queries
--
-- QUICK START
-- -----------
--   -- 1. Optionally track specific tables for detailed monitoring
--   SELECT telemetry.track_table('orders');
--
--   -- 2. Telemetry collects automatically in the background
--
--   -- 3. Query any time window to diagnose performance
--   SELECT * FROM telemetry.compare('2024-12-16 14:00', '2024-12-16 15:00');
--   SELECT * FROM telemetry.table_compare('orders', '2024-12-16 14:00', '2024-12-16 15:00');
--   SELECT * FROM telemetry.wait_summary('2024-12-16 14:00', '2024-12-16 15:00');
--
--   -- 4. Or use the recent_* views for rolling 2-hour visibility
--   SELECT * FROM telemetry.recent_waits;
--   SELECT * FROM telemetry.recent_locks;
--   SELECT * FROM telemetry.recent_activity;
--
-- FUNCTIONS
-- ---------
--   telemetry.snapshot()
--       Capture cumulative stats. Called automatically every 5 min.
--       Returns: timestamp of capture
--
--   telemetry.sample()
--       Capture point-in-time activity. Called automatically every 30 sec.
--       Returns: timestamp of capture
--
--   telemetry.track_table(name, schema DEFAULT 'public')
--       Register a table for per-table monitoring.
--       Returns: confirmation message
--
--   telemetry.untrack_table(name, schema DEFAULT 'public')
--       Stop monitoring a table.
--       Returns: confirmation message
--
--   telemetry.list_tracked_tables()
--       Show all tracked tables.
--       Returns: table of (schemaname, relname, added_at)
--
--   telemetry.compare(start_time, end_time)
--       Compare cumulative stats between two time points.
--       Returns: single row with deltas for WAL, checkpoints, bgwriter, I/O
--
--   telemetry.table_compare(table, start_time, end_time, schema DEFAULT 'public')
--       Compare table stats between two time points.
--       Returns: single row with size delta, tuple counts, vacuum activity
--
--   telemetry.wait_summary(start_time, end_time)
--       Aggregate wait events over a time period.
--       Returns: rows ordered by total_waiters DESC
--       Columns: backend_type, wait_event_type, wait_event, sample_count,
--                total_waiters, avg_waiters, max_waiters, pct_of_samples
--
--   telemetry.cleanup(retain_interval DEFAULT '7 days')
--       Remove old telemetry data.
--       Returns: (deleted_snapshots, deleted_samples)
--
-- VIEWS
-- -----
--   telemetry.deltas
--       Changes between consecutive snapshots.
--       Key columns: checkpoint_occurred, wal_bytes_delta, wal_bytes_pretty,
--                    ckpt_write_time_ms, bgw_buffers_backend_delta,
--                    temp_files_delta, temp_bytes_pretty
--
--   telemetry.table_deltas
--       Changes to tracked tables between consecutive snapshots.
--       Key columns: size_delta_pretty, inserts_delta, n_dead_tup,
--                    dead_tuple_ratio, autovacuum_ran, autoanalyze_ran
--
--   telemetry.recent_waits
--       Wait events from last 2 hours.
--       Columns: captured_at, backend_type, wait_event_type, wait_event, state, count
--
--   telemetry.recent_activity
--       Active sessions from last 2 hours.
--       Columns: captured_at, pid, usename, backend_type, state, wait_event,
--                running_for, query_preview
--
--   telemetry.recent_locks
--       Lock contention from last 2 hours.
--       Columns: captured_at, blocked_pid, blocked_duration, blocking_pid,
--                lock_type, locked_relation, blocked_query_preview
--
--   telemetry.recent_progress
--       Operation progress (vacuum/copy/analyze/create_index) from last 2 hours.
--       Columns: captured_at, progress_type, pid, relname, phase,
--                blocks_pct, tuples_done, bytes_done_pretty
--
--   telemetry.recent_replication
--       Replication lag from last 2 hours.
--       Columns: captured_at, application_name, state, sync_state,
--                replay_lag_bytes, replay_lag_pretty, write_lag, flush_lag, replay_lag
--
-- INTERPRETING RESULTS
-- --------------------
--   Checkpoint pressure:
--     - checkpoint_occurred=true with large ckpt_write_time_ms => checkpoint during batch
--     - ckpt_requested_delta > 0 => forced checkpoint (WAL exceeded max_wal_size)
--
--   WAL pressure:
--     - Large wal_sync_time_ms => WAL fsync bottleneck
--     - Compare wal_bytes_delta to expected (row_count * avg_row_size)
--
--   Shared buffer pressure (PG15/16):
--     - bgw_buffers_backend_delta > 0 => backends writing directly (bad)
--     - bgw_buffers_backend_fsync_delta > 0 => backends doing fsync (very bad)
--
--   I/O contention (PG16+):
--     - High io_checkpointer_write_time => checkpoint I/O pressure
--     - High io_autovacuum_writes => vacuum competing for I/O bandwidth
--     - High io_client_writes => shared_buffers exhaustion
--
--   Autovacuum interference:
--     - autovacuum_ran=true on target table during batch
--     - Check recent_progress for vacuum phase/duration
--
--   Lock contention:
--     - Check recent_locks for blocked_duration
--     - Cross-reference with recent_activity for blocking queries
--
--   Wait events:
--     - LWLock:BufferContent => buffer contention
--     - IO:DataFileRead/Write => disk I/O bottleneck
--     - Lock:transactionid => row-level lock contention
--
--   Temp file spills (work_mem exhaustion):
--     - temp_files_delta > 0 => sorts/hashes spilling to disk
--     - Large temp_bytes_delta => significant disk I/O from spills
--     - Resolution: increase work_mem (per-session or globally)
--
--   Replication lag (sync replication):
--     - recent_replication shows large replay_lag_bytes
--     - write_lag/flush_lag/replay_lag intervals growing
--     - With sync replication, batch waits for replica acknowledgment
--     - Resolution: check replica health, network latency, or switch to async
--
-- DIAGNOSTIC PATTERNS (from real-world testing)
-- ---------------------------------------------
--   These patterns were validated against PostgreSQL 15 on Supabase.
--
--   PATTERN 1: Lock Contention
--   Symptoms:
--     - Batch takes 10x longer than expected
--     - telemetry.recent_locks shows blocked_pid entries
--     - wait_summary() shows Lock:relation or Lock:extend events
--   Example findings:
--     - blocked_pid=12345, blocking_pid=12346, blocked_duration='00:00:09'
--     - Wait event: Lock:relation with high occurrence count
--   Resolution:
--     - Identify blocking query from recent_locks.blocking_query
--     - Consider table partitioning, shorter transactions, or scheduling
--
--   PATTERN 2: Buffer/WAL Pressure (Concurrent Writers)
--   Symptoms:
--     - Batch takes 10-20x longer than baseline
--     - bgw_buffers_backend_delta > 0 (backends forced to write directly)
--     - High wal_bytes_delta relative to data volume
--   Example findings (4 concurrent writers vs 1 writer baseline):
--     | Metric                   | Baseline | Concurrent |
--     |--------------------------|----------|------------|
--     | elapsed_seconds          | 1.6      | 19.2       |
--     | wal_bytes                | 47 MB    | 144 MB     |
--     | bgw_buffers_alloc_delta  | 4,400    | 15,152     |
--     | bgw_buffers_backend_delta| 0        | 15,153     | <-- KEY INDICATOR
--   Wait events observed:
--     - LWLock:WALWrite (WAL contention between writers)
--     - Lock:extend (relation extension locks)
--     - IO:DataFileExtend (data file I/O)
--   Resolution:
--     - Reduce concurrent writers or serialize large batches
--     - Increase shared_buffers or wal_buffers
--     - Consider faster storage (NVMe, io2)
--
--   PATTERN 3: Checkpoint During Batch
--   Symptoms:
--     - compare() shows checkpoint_occurred=true
--     - High ckpt_write_time_ms during batch window
--     - ckpt_requested_delta > 0 (WAL exceeded max_wal_size)
--   Resolution:
--     - Increase max_wal_size to avoid mid-batch checkpoints
--     - Schedule large batches after checkpoint_timeout
--     - Monitor wal_bytes_delta to predict checkpoint timing
--
--   PATTERN 4: Autovacuum Interference
--   Symptoms:
--     - table_compare() shows autovacuum_ran=true during batch
--     - recent_progress shows vacuum phases overlapping batch
--     - Wait events: LWLock:BufferContent, IO:DataFileRead
--   Resolution:
--     - Schedule batches to avoid autovacuum (check pg_stat_user_tables)
--     - Use ALTER TABLE ... SET (autovacuum_enabled = false) temporarily
--     - Increase autovacuum_vacuum_cost_delay to slow vacuum during batch
--
--   PATTERN 5: Temp File Spills (work_mem exhaustion)
--   Symptoms:
--     - Batch with complex queries (JOINs, sorts, aggregations) runs slowly
--     - compare() shows temp_files_delta > 0
--     - Large temp_bytes_delta (e.g., hundreds of MB or GB)
--   Resolution:
--     - Increase work_mem for the session: SET work_mem = '256MB';
--     - Optimize query to reduce memory usage (add indexes, limit result sets)
--     - Consider maintenance_work_mem for CREATE INDEX or VACUUM
--
--   PATTERN 6: Replication Lag (sync replication)
--   Symptoms:
--     - Batch runs slowly despite no local resource contention
--     - recent_replication shows large replay_lag_bytes
--     - write_lag/flush_lag intervals in seconds or more
--     - synchronous_commit = on with synchronous_standby_names set
--   Resolution:
--     - Check replica health (disk I/O, network, CPU)
--     - Consider switching to asynchronous replication for batch jobs
--     - Use SET LOCAL synchronous_commit = off; within batch transaction
--
--   QUICK DIAGNOSIS CHECKLIST
--   -------------------------
--   For a slow batch between START_TIME and END_TIME:
--
--   1. Overall health:
--      SELECT * FROM telemetry.compare('START_TIME', 'END_TIME');
--      => Check: checkpoint_occurred, bgw_buffers_backend_delta, wal_bytes,
--                temp_files_delta, temp_bytes_pretty
--
--   2. Lock contention:
--      SELECT * FROM telemetry.recent_locks
--      WHERE captured_at BETWEEN 'START_TIME' AND 'END_TIME';
--      => Look for: blocked_pid entries, blocked_duration > 1s
--
--   3. Wait events:
--      SELECT * FROM telemetry.wait_summary('START_TIME', 'END_TIME');
--      => Red flags: Lock:*, LWLock:WALWrite, LWLock:BufferContent
--
--   4. Table-specific (if tracking):
--      SELECT * FROM telemetry.table_compare('mytable', 'START_TIME', 'END_TIME');
--      => Check: autovacuum_ran, dead_tuple_ratio, size_delta
--
--   5. Active operations:
--      SELECT * FROM telemetry.recent_progress
--      WHERE captured_at BETWEEN 'START_TIME' AND 'END_TIME';
--      => Check: overlapping vacuum, COPY, or index builds
--
--   6. Replication lag (if using sync replication):
--      SELECT * FROM telemetry.recent_replication
--      WHERE captured_at BETWEEN 'START_TIME' AND 'END_TIME';
--      => Check: replay_lag_bytes, write_lag/flush_lag intervals
--
-- PG VERSION DIFFERENCES
-- ----------------------
--   PG15: Checkpoint stats in pg_stat_bgwriter, no pg_stat_io
--   PG16: Checkpoint stats in pg_stat_bgwriter, pg_stat_io available
--   PG17: Checkpoint stats in pg_stat_checkpointer, pg_stat_io available
--
-- SCHEDULED JOBS (pg_cron)
-- ------------------------
--   telemetry_snapshot  : */5 * * * *   (every 5 minutes)
--   telemetry_sample    : 30 seconds    (if pg_cron 1.4.1+) or * * * * * (every minute, fallback)
--   telemetry_cleanup   : 0 3 * * *     (daily at 3 AM, retains 7 days)
--
--   NOTE: The installer auto-detects pg_cron version. If < 1.4.1 (e.g., "1.4-1"),
--   it falls back to minute-level sampling and logs a notice.
--
-- UNINSTALL
-- ---------
--   SELECT cron.unschedule('telemetry_snapshot');
--   SELECT cron.unschedule('telemetry_sample');
--   SELECT cron.unschedule('telemetry_cleanup');
--   DROP SCHEMA telemetry CASCADE;
--
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS telemetry;

-- -----------------------------------------------------------------------------
-- Table: snapshots
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.snapshots (
    id              SERIAL PRIMARY KEY,
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    pg_version      INTEGER NOT NULL,

    -- WAL stats (pg_stat_wal)
    wal_records     BIGINT,
    wal_fpi         BIGINT,
    wal_bytes       BIGINT,
    wal_write_time  DOUBLE PRECISION,
    wal_sync_time   DOUBLE PRECISION,

    -- Checkpoint info (pg_control_checkpoint)
    checkpoint_lsn  PG_LSN,
    checkpoint_time TIMESTAMPTZ,

    -- Checkpointer stats
    ckpt_timed      BIGINT,
    ckpt_requested  BIGINT,
    ckpt_write_time DOUBLE PRECISION,
    ckpt_sync_time  DOUBLE PRECISION,
    ckpt_buffers    BIGINT,

    -- BGWriter stats
    bgw_buffers_clean       BIGINT,
    bgw_maxwritten_clean    BIGINT,
    bgw_buffers_alloc       BIGINT,
    bgw_buffers_backend     BIGINT,           -- PG15/16 only
    bgw_buffers_backend_fsync BIGINT,         -- PG15/16 only

    -- Autovacuum stats
    autovacuum_workers      INTEGER,          -- currently active workers

    -- Replication slot stats
    slots_count             INTEGER,
    slots_max_retained_wal  BIGINT,           -- max retained WAL bytes across all slots

    -- pg_stat_io (PG16+ only) - key backend types
    io_checkpointer_writes      BIGINT,
    io_checkpointer_write_time  DOUBLE PRECISION,
    io_checkpointer_fsyncs      BIGINT,
    io_checkpointer_fsync_time  DOUBLE PRECISION,
    io_autovacuum_writes        BIGINT,
    io_autovacuum_write_time    DOUBLE PRECISION,
    io_client_writes            BIGINT,
    io_client_write_time        DOUBLE PRECISION,
    io_bgwriter_writes          BIGINT,
    io_bgwriter_write_time      DOUBLE PRECISION,

    -- Temp file usage (pg_stat_database)
    temp_files                  BIGINT,           -- cumulative temp files created
    temp_bytes                  BIGINT            -- cumulative temp bytes written
);

CREATE INDEX IF NOT EXISTS snapshots_captured_at_idx ON telemetry.snapshots(captured_at);

-- -----------------------------------------------------------------------------
-- Table: tracked_tables - Tables to monitor for batch operations
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.tracked_tables (
    relid           OID PRIMARY KEY,
    schemaname      TEXT NOT NULL DEFAULT 'public',
    relname         TEXT NOT NULL,
    added_at        TIMESTAMPTZ DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Table: table_snapshots - Per-table stats captured with each snapshot
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.table_snapshots (
    snapshot_id             INTEGER REFERENCES telemetry.snapshots(id) ON DELETE CASCADE,
    relid                   OID,
    schemaname              TEXT,
    relname                 TEXT,
    -- Size
    pg_relation_size        BIGINT,
    pg_total_relation_size  BIGINT,
    pg_indexes_size         BIGINT,
    -- Tuple counts (point-in-time)
    n_live_tup              BIGINT,
    n_dead_tup              BIGINT,
    -- Cumulative DML counters
    n_tup_ins               BIGINT,
    n_tup_upd               BIGINT,
    n_tup_del               BIGINT,
    n_tup_hot_upd           BIGINT,
    -- Vacuum/analyze timestamps
    last_vacuum             TIMESTAMPTZ,
    last_autovacuum         TIMESTAMPTZ,
    last_analyze            TIMESTAMPTZ,
    last_autoanalyze        TIMESTAMPTZ,
    -- Vacuum/analyze counts (cumulative)
    vacuum_count            BIGINT,
    autovacuum_count        BIGINT,
    analyze_count           BIGINT,
    autoanalyze_count       BIGINT,
    PRIMARY KEY (snapshot_id, relid)
);

-- -----------------------------------------------------------------------------
-- Table: replication_snapshots - Per-replica stats captured with each snapshot
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.replication_snapshots (
    snapshot_id             INTEGER REFERENCES telemetry.snapshots(id) ON DELETE CASCADE,
    pid                     INTEGER NOT NULL,
    client_addr             INET,
    application_name        TEXT,
    state                   TEXT,
    sync_state              TEXT,
    -- LSN positions
    sent_lsn                PG_LSN,
    write_lsn               PG_LSN,
    flush_lsn               PG_LSN,
    replay_lsn              PG_LSN,
    -- Lag intervals (NULL if not available)
    write_lag               INTERVAL,
    flush_lag               INTERVAL,
    replay_lag              INTERVAL,
    PRIMARY KEY (snapshot_id, pid)
);

-- -----------------------------------------------------------------------------
-- Table: statement_snapshots - pg_stat_statements metrics per snapshot
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.statement_snapshots (
    snapshot_id         INTEGER REFERENCES telemetry.snapshots(id) ON DELETE CASCADE,
    queryid             BIGINT NOT NULL,
    userid              OID,
    dbid                OID,

    -- Query text (truncated for storage)
    query_preview       TEXT,

    -- Cumulative counters (for delta calculation)
    calls               BIGINT,
    total_exec_time     DOUBLE PRECISION,
    min_exec_time       DOUBLE PRECISION,
    max_exec_time       DOUBLE PRECISION,
    mean_exec_time      DOUBLE PRECISION,
    rows                BIGINT,

    -- Block I/O
    shared_blks_hit     BIGINT,
    shared_blks_read    BIGINT,
    shared_blks_dirtied BIGINT,
    shared_blks_written BIGINT,
    temp_blks_read      BIGINT,
    temp_blks_written   BIGINT,

    -- I/O timing (if track_io_timing enabled)
    blk_read_time       DOUBLE PRECISION,
    blk_write_time      DOUBLE PRECISION,

    -- WAL (PG13+)
    wal_records         BIGINT,
    wal_bytes           NUMERIC,

    PRIMARY KEY (snapshot_id, queryid, dbid)
);

CREATE INDEX IF NOT EXISTS statement_snapshots_queryid_idx
    ON telemetry.statement_snapshots(queryid);

-- -----------------------------------------------------------------------------
-- Table: samples - High-frequency sampling (every 30 seconds)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.samples (
    id              SERIAL PRIMARY KEY,
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS samples_captured_at_idx ON telemetry.samples(captured_at);

-- -----------------------------------------------------------------------------
-- Table: wait_samples - Aggregated wait events per sample
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.wait_samples (
    sample_id           INTEGER REFERENCES telemetry.samples(id) ON DELETE CASCADE,
    backend_type        TEXT NOT NULL,
    wait_event_type     TEXT NOT NULL,
    wait_event          TEXT NOT NULL,
    state               TEXT NOT NULL,
    count               INTEGER NOT NULL,
    PRIMARY KEY (sample_id, backend_type, wait_event_type, wait_event, state)
);

-- -----------------------------------------------------------------------------
-- Table: activity_samples - Top active sessions per sample
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.activity_samples (
    sample_id           INTEGER REFERENCES telemetry.samples(id) ON DELETE CASCADE,
    pid                 INTEGER NOT NULL,
    usename             TEXT,
    application_name    TEXT,
    backend_type        TEXT,
    state               TEXT,
    wait_event_type     TEXT,
    wait_event          TEXT,
    query_start         TIMESTAMPTZ,
    state_change        TIMESTAMPTZ,
    query_preview       TEXT,
    PRIMARY KEY (sample_id, pid)
);

-- -----------------------------------------------------------------------------
-- Table: progress_samples - Operation progress (vacuum, copy, analyze, etc.)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.progress_samples (
    sample_id           INTEGER REFERENCES telemetry.samples(id) ON DELETE CASCADE,
    progress_type       TEXT NOT NULL,      -- 'vacuum', 'copy', 'analyze', 'create_index'
    pid                 INTEGER NOT NULL,
    relid               OID,
    relname             TEXT,
    phase               TEXT,
    blocks_total        BIGINT,
    blocks_done         BIGINT,
    tuples_total        BIGINT,
    tuples_done         BIGINT,
    bytes_total         BIGINT,
    bytes_done          BIGINT,
    details             JSONB,              -- Type-specific additional fields
    PRIMARY KEY (sample_id, progress_type, pid)
);

-- -----------------------------------------------------------------------------
-- Table: lock_samples - Blocking lock relationships
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.lock_samples (
    sample_id               INTEGER REFERENCES telemetry.samples(id) ON DELETE CASCADE,
    blocked_pid             INTEGER NOT NULL,
    blocked_user            TEXT,
    blocked_app             TEXT,
    blocked_query_preview   TEXT,
    blocked_duration        INTERVAL,
    blocking_pid            INTEGER NOT NULL,
    blocking_user           TEXT,
    blocking_app            TEXT,
    blocking_query_preview  TEXT,
    lock_type               TEXT,
    locked_relation         TEXT,
    PRIMARY KEY (sample_id, blocked_pid, blocking_pid)
);

-- -----------------------------------------------------------------------------
-- Helper: Pretty-print bytes
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry._pretty_bytes(bytes BIGINT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN bytes IS NULL THEN NULL
        WHEN bytes >= 1073741824 THEN round(bytes / 1073741824.0, 2)::text || ' GB'
        WHEN bytes >= 1048576    THEN round(bytes / 1048576.0, 2)::text || ' MB'
        WHEN bytes >= 1024       THEN round(bytes / 1024.0, 2)::text || ' KB'
        ELSE bytes::text || ' B'
    END
$$;

-- -----------------------------------------------------------------------------
-- Helper: Get PG major version
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry._pg_version()
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT current_setting('server_version_num')::integer / 10000
$$;

-- -----------------------------------------------------------------------------
-- Table: config - Telemetry configuration settings
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry.config (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  TIMESTAMPTZ DEFAULT now()
);

-- Default configuration
INSERT INTO telemetry.config (key, value) VALUES
    ('mode', 'normal'),
    ('statements_enabled', 'auto'),
    ('statements_top_n', '50'),
    ('statements_min_calls', '1'),
    ('enable_locks', 'true'),
    ('enable_progress', 'true')
ON CONFLICT (key) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Helper: Get config value with default
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry._get_config(p_key TEXT, p_default TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT value FROM telemetry.config WHERE key = p_key),
        p_default
    )
$$;

-- -----------------------------------------------------------------------------
-- Helper: Check if pg_stat_statements is available
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry._has_pg_stat_statements()
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'
    )
$$;

-- -----------------------------------------------------------------------------
-- Table tracking functions
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.track_table(p_table TEXT, p_schema TEXT DEFAULT 'public')
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_relid OID;
BEGIN
    SELECT c.oid INTO v_relid
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = p_table AND n.nspname = p_schema AND c.relkind = 'r';

    IF v_relid IS NULL THEN
        RAISE EXCEPTION 'Table %.% not found', p_schema, p_table;
    END IF;

    INSERT INTO telemetry.tracked_tables (relid, schemaname, relname)
    VALUES (v_relid, p_schema, p_table)
    ON CONFLICT (relid) DO NOTHING;

    RETURN format('Now tracking %I.%I', p_schema, p_table);
END;
$$;

CREATE OR REPLACE FUNCTION telemetry.untrack_table(p_table TEXT, p_schema TEXT DEFAULT 'public')
RETURNS TEXT
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM telemetry.tracked_tables
    WHERE relname = p_table AND schemaname = p_schema;

    IF NOT FOUND THEN
        RETURN format('Table %I.%I was not being tracked', p_schema, p_table);
    END IF;

    RETURN format('Stopped tracking %I.%I', p_schema, p_table);
END;
$$;

CREATE OR REPLACE FUNCTION telemetry.list_tracked_tables()
RETURNS TABLE(schemaname TEXT, relname TEXT, added_at TIMESTAMPTZ)
LANGUAGE sql STABLE AS $$
    SELECT schemaname, relname, added_at FROM telemetry.tracked_tables ORDER BY added_at;
$$;

-- -----------------------------------------------------------------------------
-- telemetry.sample() - High-frequency sampling (wait events, activity, progress, locks)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.sample()
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql AS $$
DECLARE
    v_sample_id INTEGER;
    v_captured_at TIMESTAMPTZ := now();
    v_enable_locks BOOLEAN;
    v_enable_progress BOOLEAN;
    v_pg_version INTEGER;
BEGIN
    -- Get configuration
    v_enable_locks := COALESCE(
        telemetry._get_config('enable_locks', 'true')::boolean,
        TRUE
    );
    v_enable_progress := COALESCE(
        telemetry._get_config('enable_progress', 'true')::boolean,
        TRUE
    );
    v_pg_version := telemetry._pg_version();

    -- Create sample record
    INSERT INTO telemetry.samples (captured_at)
    VALUES (v_captured_at)
    RETURNING id INTO v_sample_id;

    -- Wait events (aggregated by backend_type, wait_event_type, wait_event, state)
    -- Always captured - low overhead
    INSERT INTO telemetry.wait_samples (sample_id, backend_type, wait_event_type, wait_event, state, count)
    SELECT
        v_sample_id,
        COALESCE(backend_type, 'unknown'),
        COALESCE(wait_event_type, 'Running'),
        COALESCE(wait_event, 'CPU'),
        COALESCE(state, 'unknown'),
        count(*)::integer
    FROM pg_stat_activity
    WHERE pid != pg_backend_pid()
    GROUP BY backend_type, wait_event_type, wait_event, state;

    -- Active sessions (top 25 by duration, non-idle)
    -- Always captured - low overhead
    INSERT INTO telemetry.activity_samples (
        sample_id, pid, usename, application_name, backend_type,
        state, wait_event_type, wait_event, query_start, state_change, query_preview
    )
    SELECT
        v_sample_id,
        pid,
        usename,
        application_name,
        backend_type,
        state,
        wait_event_type,
        wait_event,
        query_start,
        state_change,
        left(query, 200)
    FROM pg_stat_activity
    WHERE state != 'idle' AND pid != pg_backend_pid()
    ORDER BY query_start ASC NULLS LAST
    LIMIT 25;

    -- Progress tracking (conditionally captured)
    IF v_enable_progress THEN
    -- Vacuum progress (handle PG17 column changes)
    IF v_pg_version >= 17 THEN
        INSERT INTO telemetry.progress_samples (
            sample_id, progress_type, pid, relid, relname, phase,
            blocks_total, blocks_done, tuples_total, tuples_done, details
        )
        SELECT
            v_sample_id,
            'vacuum',
            p.pid,
            p.relid,
            p.relid::regclass::text,
            p.phase,
            p.heap_blks_total,
            p.heap_blks_vacuumed,
            p.max_dead_tuple_bytes,
            p.dead_tuple_bytes,
            jsonb_build_object(
                'heap_blks_scanned', p.heap_blks_scanned,
                'index_vacuum_count', p.index_vacuum_count,
                'num_dead_item_ids', p.num_dead_item_ids
            )
        FROM pg_stat_progress_vacuum p;
    ELSE
        INSERT INTO telemetry.progress_samples (
            sample_id, progress_type, pid, relid, relname, phase,
            blocks_total, blocks_done, tuples_total, tuples_done, details
        )
        SELECT
            v_sample_id,
            'vacuum',
            p.pid,
            p.relid,
            p.relid::regclass::text,
            p.phase,
            p.heap_blks_total,
            p.heap_blks_vacuumed,
            p.max_dead_tuples,
            p.num_dead_tuples,
            jsonb_build_object(
                'heap_blks_scanned', p.heap_blks_scanned,
                'index_vacuum_count', p.index_vacuum_count
            )
        FROM pg_stat_progress_vacuum p;
    END IF;

    -- COPY progress
    INSERT INTO telemetry.progress_samples (
        sample_id, progress_type, pid, relid, relname, phase,
        tuples_done, bytes_total, bytes_done, details
    )
    SELECT
        v_sample_id,
        'copy',
        p.pid,
        p.relid,
        p.relid::regclass::text,
        p.command || '/' || p.type,
        p.tuples_processed,
        p.bytes_total,
        p.bytes_processed,
        jsonb_build_object(
            'tuples_excluded', p.tuples_excluded
        )
    FROM pg_stat_progress_copy p;

    -- Analyze progress
    INSERT INTO telemetry.progress_samples (
        sample_id, progress_type, pid, relid, relname, phase,
        blocks_total, blocks_done, details
    )
    SELECT
        v_sample_id,
        'analyze',
        p.pid,
        p.relid,
        p.relid::regclass::text,
        p.phase,
        p.sample_blks_total,
        p.sample_blks_scanned,
        jsonb_build_object(
            'ext_stats_total', p.ext_stats_total,
            'ext_stats_computed', p.ext_stats_computed,
            'child_tables_total', p.child_tables_total,
            'child_tables_done', p.child_tables_done
        )
    FROM pg_stat_progress_analyze p;

    -- Create index progress
    INSERT INTO telemetry.progress_samples (
        sample_id, progress_type, pid, relid, relname, phase,
        blocks_total, blocks_done, tuples_total, tuples_done, details
    )
    SELECT
        v_sample_id,
        'create_index',
        p.pid,
        p.relid,
        p.relid::regclass::text,
        p.phase,
        p.blocks_total,
        p.blocks_done,
        p.tuples_total,
        p.tuples_done,
        jsonb_build_object(
            'index_relid', p.index_relid,
            'command', p.command,
            'lockers_total', p.lockers_total,
            'lockers_done', p.lockers_done,
            'partitions_total', p.partitions_total,
            'partitions_done', p.partitions_done
        )
    FROM pg_stat_progress_create_index p;
    END IF;  -- v_enable_progress

    -- Lock sampling (conditionally captured)
    IF v_enable_locks THEN
    -- Blocking locks
    INSERT INTO telemetry.lock_samples (
        sample_id, blocked_pid, blocked_user, blocked_app, blocked_query_preview, blocked_duration,
        blocking_pid, blocking_user, blocking_app, blocking_query_preview, lock_type, locked_relation
    )
    SELECT DISTINCT ON (blocked.pid, blocking.pid)
        v_sample_id,
        blocked.pid,
        blocked.usename,
        blocked.application_name,
        left(blocked.query, 200),
        v_captured_at - blocked.query_start,
        blocking.pid,
        blocking.usename,
        blocking.application_name,
        left(blocking.query, 200),
        bl.locktype,
        CASE WHEN bl.relation IS NOT NULL THEN bl.relation::regclass::text ELSE NULL END
    FROM pg_locks bl
    JOIN pg_stat_activity blocked ON blocked.pid = bl.pid
    JOIN pg_locks kl ON (
        kl.locktype = bl.locktype AND
        kl.database IS NOT DISTINCT FROM bl.database AND
        kl.relation IS NOT DISTINCT FROM bl.relation AND
        kl.page IS NOT DISTINCT FROM bl.page AND
        kl.tuple IS NOT DISTINCT FROM bl.tuple AND
        kl.virtualxid IS NOT DISTINCT FROM bl.virtualxid AND
        kl.transactionid IS NOT DISTINCT FROM bl.transactionid AND
        kl.classid IS NOT DISTINCT FROM bl.classid AND
        kl.objid IS NOT DISTINCT FROM bl.objid AND
        kl.objsubid IS NOT DISTINCT FROM bl.objsubid AND
        kl.pid != bl.pid
    )
    JOIN pg_stat_activity blocking ON blocking.pid = kl.pid
    WHERE NOT bl.granted AND kl.granted;
    END IF;  -- v_enable_locks

    RETURN v_captured_at;
END;
$$;

-- -----------------------------------------------------------------------------
-- telemetry.snapshot() - Capture current state
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.snapshot()
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql AS $$
DECLARE
    v_pg_version INTEGER;
    v_captured_at TIMESTAMPTZ := now();
    v_snapshot_id INTEGER;
    v_autovacuum_workers INTEGER;
    v_slots_count INTEGER;
    v_slots_max_retained BIGINT;
    -- Temp file stats
    v_temp_files BIGINT;
    v_temp_bytes BIGINT;
    -- pg_stat_io values (PG16+)
    v_io_ckpt_writes BIGINT;
    v_io_ckpt_write_time DOUBLE PRECISION;
    v_io_ckpt_fsyncs BIGINT;
    v_io_ckpt_fsync_time DOUBLE PRECISION;
    v_io_av_writes BIGINT;
    v_io_av_write_time DOUBLE PRECISION;
    v_io_client_writes BIGINT;
    v_io_client_write_time DOUBLE PRECISION;
    v_io_bgw_writes BIGINT;
    v_io_bgw_write_time DOUBLE PRECISION;
BEGIN
    v_pg_version := telemetry._pg_version();

    -- Count active autovacuum workers
    SELECT count(*)::integer INTO v_autovacuum_workers
    FROM pg_stat_activity
    WHERE backend_type = 'autovacuum worker';

    -- Replication slot stats
    SELECT
        count(*)::integer,
        COALESCE(max(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)), 0)
    INTO v_slots_count, v_slots_max_retained
    FROM pg_replication_slots;

    -- Temp file stats (current database)
    SELECT COALESCE(temp_files, 0), COALESCE(temp_bytes, 0)
    INTO v_temp_files, v_temp_bytes
    FROM pg_stat_database
    WHERE datname = current_database();

    -- pg_stat_io (PG16+)
    IF v_pg_version >= 16 THEN
        -- Checkpointer I/O
        SELECT COALESCE(sum(writes), 0), COALESCE(sum(write_time), 0),
               COALESCE(sum(fsyncs), 0), COALESCE(sum(fsync_time), 0)
        INTO v_io_ckpt_writes, v_io_ckpt_write_time, v_io_ckpt_fsyncs, v_io_ckpt_fsync_time
        FROM pg_stat_io WHERE backend_type = 'checkpointer';

        -- Autovacuum worker I/O
        SELECT COALESCE(sum(writes), 0), COALESCE(sum(write_time), 0)
        INTO v_io_av_writes, v_io_av_write_time
        FROM pg_stat_io WHERE backend_type = 'autovacuum worker';

        -- Client backend I/O
        SELECT COALESCE(sum(writes), 0), COALESCE(sum(write_time), 0)
        INTO v_io_client_writes, v_io_client_write_time
        FROM pg_stat_io WHERE backend_type = 'client backend';

        -- Background writer I/O
        SELECT COALESCE(sum(writes), 0), COALESCE(sum(write_time), 0)
        INTO v_io_bgw_writes, v_io_bgw_write_time
        FROM pg_stat_io WHERE backend_type = 'background writer';
    END IF;

    IF v_pg_version = 17 THEN
        -- PG17: checkpointer stats in pg_stat_checkpointer
        INSERT INTO telemetry.snapshots (
            captured_at, pg_version,
            wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
            checkpoint_lsn, checkpoint_time,
            ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
            bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
            bgw_buffers_backend, bgw_buffers_backend_fsync,
            autovacuum_workers, slots_count, slots_max_retained_wal,
            io_checkpointer_writes, io_checkpointer_write_time, io_checkpointer_fsyncs, io_checkpointer_fsync_time,
            io_autovacuum_writes, io_autovacuum_write_time,
            io_client_writes, io_client_write_time,
            io_bgwriter_writes, io_bgwriter_write_time,
            temp_files, temp_bytes
        )
        SELECT
            v_captured_at, v_pg_version,
            w.wal_records, w.wal_fpi, w.wal_bytes, w.wal_write_time, w.wal_sync_time,
            (pg_control_checkpoint()).redo_lsn,
            (pg_control_checkpoint()).checkpoint_time,
            c.num_timed, c.num_requested, c.write_time, c.sync_time, c.buffers_written,
            b.buffers_clean, b.maxwritten_clean, b.buffers_alloc,
            NULL, NULL,  -- buffers_backend not in PG17
            v_autovacuum_workers, v_slots_count, v_slots_max_retained,
            v_io_ckpt_writes, v_io_ckpt_write_time, v_io_ckpt_fsyncs, v_io_ckpt_fsync_time,
            v_io_av_writes, v_io_av_write_time,
            v_io_client_writes, v_io_client_write_time,
            v_io_bgw_writes, v_io_bgw_write_time,
            v_temp_files, v_temp_bytes
        FROM pg_stat_wal w
        CROSS JOIN pg_stat_checkpointer c
        CROSS JOIN pg_stat_bgwriter b
        RETURNING id INTO v_snapshot_id;

    ELSIF v_pg_version = 16 THEN
        -- PG16: checkpointer stats in pg_stat_bgwriter, has pg_stat_io
        INSERT INTO telemetry.snapshots (
            captured_at, pg_version,
            wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
            checkpoint_lsn, checkpoint_time,
            ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
            bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
            bgw_buffers_backend, bgw_buffers_backend_fsync,
            autovacuum_workers, slots_count, slots_max_retained_wal,
            io_checkpointer_writes, io_checkpointer_write_time, io_checkpointer_fsyncs, io_checkpointer_fsync_time,
            io_autovacuum_writes, io_autovacuum_write_time,
            io_client_writes, io_client_write_time,
            io_bgwriter_writes, io_bgwriter_write_time,
            temp_files, temp_bytes
        )
        SELECT
            v_captured_at, v_pg_version,
            w.wal_records, w.wal_fpi, w.wal_bytes, w.wal_write_time, w.wal_sync_time,
            (pg_control_checkpoint()).redo_lsn,
            (pg_control_checkpoint()).checkpoint_time,
            b.checkpoints_timed, b.checkpoints_req, b.checkpoint_write_time, b.checkpoint_sync_time, b.buffers_checkpoint,
            b.buffers_clean, b.maxwritten_clean, b.buffers_alloc,
            b.buffers_backend, b.buffers_backend_fsync,
            v_autovacuum_workers, v_slots_count, v_slots_max_retained,
            v_io_ckpt_writes, v_io_ckpt_write_time, v_io_ckpt_fsyncs, v_io_ckpt_fsync_time,
            v_io_av_writes, v_io_av_write_time,
            v_io_client_writes, v_io_client_write_time,
            v_io_bgw_writes, v_io_bgw_write_time,
            v_temp_files, v_temp_bytes
        FROM pg_stat_wal w
        CROSS JOIN pg_stat_bgwriter b
        RETURNING id INTO v_snapshot_id;

    ELSIF v_pg_version = 15 THEN
        -- PG15: checkpointer stats in pg_stat_bgwriter, no pg_stat_io
        INSERT INTO telemetry.snapshots (
            captured_at, pg_version,
            wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
            checkpoint_lsn, checkpoint_time,
            ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
            bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
            bgw_buffers_backend, bgw_buffers_backend_fsync,
            autovacuum_workers, slots_count, slots_max_retained_wal,
            temp_files, temp_bytes
        )
        SELECT
            v_captured_at, v_pg_version,
            w.wal_records, w.wal_fpi, w.wal_bytes, w.wal_write_time, w.wal_sync_time,
            (pg_control_checkpoint()).redo_lsn,
            (pg_control_checkpoint()).checkpoint_time,
            b.checkpoints_timed, b.checkpoints_req, b.checkpoint_write_time, b.checkpoint_sync_time, b.buffers_checkpoint,
            b.buffers_clean, b.maxwritten_clean, b.buffers_alloc,
            b.buffers_backend, b.buffers_backend_fsync,
            v_autovacuum_workers, v_slots_count, v_slots_max_retained,
            v_temp_files, v_temp_bytes
        FROM pg_stat_wal w
        CROSS JOIN pg_stat_bgwriter b
        RETURNING id INTO v_snapshot_id;
    ELSE
        RAISE EXCEPTION 'Unsupported PostgreSQL version: %. Requires 15, 16, or 17.', v_pg_version;
    END IF;

    -- Capture stats for tracked tables
    INSERT INTO telemetry.table_snapshots (
        snapshot_id, relid, schemaname, relname,
        pg_relation_size, pg_total_relation_size, pg_indexes_size,
        n_live_tup, n_dead_tup,
        n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
        last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
        vacuum_count, autovacuum_count, analyze_count, autoanalyze_count
    )
    SELECT
        v_snapshot_id,
        t.relid,
        t.schemaname,
        t.relname,
        pg_relation_size(t.relid),
        pg_total_relation_size(t.relid),
        pg_indexes_size(t.relid),
        s.n_live_tup,
        s.n_dead_tup,
        s.n_tup_ins,
        s.n_tup_upd,
        s.n_tup_del,
        s.n_tup_hot_upd,
        s.last_vacuum,
        s.last_autovacuum,
        s.last_analyze,
        s.last_autoanalyze,
        s.vacuum_count,
        s.autovacuum_count,
        s.analyze_count,
        s.autoanalyze_count
    FROM telemetry.tracked_tables t
    JOIN pg_stat_user_tables s ON s.relid = t.relid;

    -- Capture replication stats (if any replicas connected)
    INSERT INTO telemetry.replication_snapshots (
        snapshot_id, pid, client_addr, application_name, state, sync_state,
        sent_lsn, write_lsn, flush_lsn, replay_lsn,
        write_lag, flush_lag, replay_lag
    )
    SELECT
        v_snapshot_id,
        pid,
        client_addr,
        application_name,
        state,
        sync_state,
        sent_lsn,
        write_lsn,
        flush_lsn,
        replay_lsn,
        write_lag,
        flush_lag,
        replay_lag
    FROM pg_stat_replication;

    -- Capture pg_stat_statements (if available and enabled)
    IF telemetry._has_pg_stat_statements()
       AND telemetry._get_config('statements_enabled', 'auto') != 'false'
    THEN
        BEGIN
            INSERT INTO telemetry.statement_snapshots (
                snapshot_id, queryid, userid, dbid, query_preview,
                calls, total_exec_time, min_exec_time, max_exec_time,
                mean_exec_time, rows,
                shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
                temp_blks_read, temp_blks_written,
                blk_read_time, blk_write_time,
                wal_records, wal_bytes
            )
            SELECT
                v_snapshot_id,
                s.queryid,
                s.userid,
                s.dbid,
                left(s.query, 500),
                s.calls,
                s.total_exec_time,
                s.min_exec_time,
                s.max_exec_time,
                s.mean_exec_time,
                s.rows,
                s.shared_blks_hit,
                s.shared_blks_read,
                s.shared_blks_dirtied,
                s.shared_blks_written,
                s.temp_blks_read,
                s.temp_blks_written,
                s.blk_read_time,
                s.blk_write_time,
                s.wal_records,
                s.wal_bytes
            FROM pg_stat_statements s
            WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
              AND s.calls >= COALESCE(telemetry._get_config('statements_min_calls', '1')::integer, 1)
            ORDER BY s.total_exec_time DESC
            LIMIT COALESCE(telemetry._get_config('statements_top_n', '50')::integer, 50);
        EXCEPTION
            WHEN undefined_table THEN NULL;
            WHEN undefined_column THEN NULL;
        END;
    END IF;

    RETURN v_captured_at;
END;
$$;

-- -----------------------------------------------------------------------------
-- telemetry.deltas - View showing deltas between consecutive snapshots
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW telemetry.deltas AS
SELECT
    s.id,
    s.captured_at,
    s.pg_version,
    EXTRACT(EPOCH FROM (s.captured_at - prev.captured_at))::numeric AS interval_seconds,

    -- Checkpoint
    (s.checkpoint_time IS DISTINCT FROM prev.checkpoint_time) AS checkpoint_occurred,
    s.ckpt_timed - prev.ckpt_timed AS ckpt_timed_delta,
    s.ckpt_requested - prev.ckpt_requested AS ckpt_requested_delta,
    (s.ckpt_write_time - prev.ckpt_write_time)::numeric AS ckpt_write_time_ms,
    (s.ckpt_sync_time - prev.ckpt_sync_time)::numeric AS ckpt_sync_time_ms,
    s.ckpt_buffers - prev.ckpt_buffers AS ckpt_buffers_delta,

    -- WAL
    s.wal_bytes - prev.wal_bytes AS wal_bytes_delta,
    telemetry._pretty_bytes(s.wal_bytes - prev.wal_bytes) AS wal_bytes_pretty,
    (s.wal_write_time - prev.wal_write_time)::numeric AS wal_write_time_ms,
    (s.wal_sync_time - prev.wal_sync_time)::numeric AS wal_sync_time_ms,

    -- BGWriter
    s.bgw_buffers_clean - prev.bgw_buffers_clean AS bgw_buffers_clean_delta,
    s.bgw_buffers_alloc - prev.bgw_buffers_alloc AS bgw_buffers_alloc_delta,
    s.bgw_buffers_backend - prev.bgw_buffers_backend AS bgw_buffers_backend_delta,
    s.bgw_buffers_backend_fsync - prev.bgw_buffers_backend_fsync AS bgw_buffers_backend_fsync_delta,

    -- Autovacuum (point-in-time, not delta)
    s.autovacuum_workers AS autovacuum_workers_active,

    -- Replication slots (point-in-time)
    s.slots_count,
    s.slots_max_retained_wal,
    telemetry._pretty_bytes(s.slots_max_retained_wal) AS slots_max_retained_pretty,

    -- pg_stat_io deltas (PG16+)
    s.io_checkpointer_writes - prev.io_checkpointer_writes AS io_ckpt_writes_delta,
    (s.io_checkpointer_write_time - prev.io_checkpointer_write_time)::numeric AS io_ckpt_write_time_ms,
    s.io_checkpointer_fsyncs - prev.io_checkpointer_fsyncs AS io_ckpt_fsyncs_delta,
    (s.io_checkpointer_fsync_time - prev.io_checkpointer_fsync_time)::numeric AS io_ckpt_fsync_time_ms,
    s.io_autovacuum_writes - prev.io_autovacuum_writes AS io_autovacuum_writes_delta,
    (s.io_autovacuum_write_time - prev.io_autovacuum_write_time)::numeric AS io_autovacuum_write_time_ms,
    s.io_client_writes - prev.io_client_writes AS io_client_writes_delta,
    (s.io_client_write_time - prev.io_client_write_time)::numeric AS io_client_write_time_ms,
    s.io_bgwriter_writes - prev.io_bgwriter_writes AS io_bgwriter_writes_delta,
    (s.io_bgwriter_write_time - prev.io_bgwriter_write_time)::numeric AS io_bgwriter_write_time_ms,

    -- Temp file deltas
    s.temp_files - prev.temp_files AS temp_files_delta,
    s.temp_bytes - prev.temp_bytes AS temp_bytes_delta,
    telemetry._pretty_bytes(s.temp_bytes - prev.temp_bytes) AS temp_bytes_pretty

FROM telemetry.snapshots s
JOIN telemetry.snapshots prev ON prev.id = (
    SELECT MAX(id) FROM telemetry.snapshots WHERE id < s.id
)
ORDER BY s.captured_at DESC;

-- -----------------------------------------------------------------------------
-- telemetry.compare(start_time, end_time) - Compare two time points
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.compare(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    start_snapshot_at       TIMESTAMPTZ,
    end_snapshot_at         TIMESTAMPTZ,
    elapsed_seconds         NUMERIC,

    checkpoint_occurred     BOOLEAN,
    ckpt_timed_delta        BIGINT,
    ckpt_requested_delta    BIGINT,
    ckpt_write_time_ms      NUMERIC,
    ckpt_sync_time_ms       NUMERIC,
    ckpt_buffers_delta      BIGINT,

    wal_bytes_delta         BIGINT,
    wal_bytes_pretty        TEXT,
    wal_write_time_ms       NUMERIC,
    wal_sync_time_ms        NUMERIC,

    bgw_buffers_clean_delta       BIGINT,
    bgw_buffers_alloc_delta       BIGINT,
    bgw_buffers_backend_delta     BIGINT,
    bgw_buffers_backend_fsync_delta BIGINT,

    -- Replication slots (max during period - use end snapshot)
    slots_count             INTEGER,
    slots_max_retained_wal  BIGINT,
    slots_max_retained_pretty TEXT,

    -- pg_stat_io deltas (PG16+)
    io_ckpt_writes_delta          BIGINT,
    io_ckpt_write_time_ms         NUMERIC,
    io_ckpt_fsyncs_delta          BIGINT,
    io_ckpt_fsync_time_ms         NUMERIC,
    io_autovacuum_writes_delta    BIGINT,
    io_autovacuum_write_time_ms   NUMERIC,
    io_client_writes_delta        BIGINT,
    io_client_write_time_ms       NUMERIC,
    io_bgwriter_writes_delta      BIGINT,
    io_bgwriter_write_time_ms     NUMERIC,

    -- Temp file stats
    temp_files_delta              BIGINT,
    temp_bytes_delta              BIGINT,
    temp_bytes_pretty             TEXT
)
LANGUAGE sql STABLE AS $$
    WITH
    start_snap AS (
        SELECT * FROM telemetry.snapshots
        WHERE captured_at <= p_start_time
        ORDER BY captured_at DESC
        LIMIT 1
    ),
    end_snap AS (
        SELECT * FROM telemetry.snapshots
        WHERE captured_at >= p_end_time
        ORDER BY captured_at ASC
        LIMIT 1
    )
    SELECT
        s.captured_at,
        e.captured_at,
        EXTRACT(EPOCH FROM (e.captured_at - s.captured_at))::numeric,

        (s.checkpoint_time IS DISTINCT FROM e.checkpoint_time),
        e.ckpt_timed - s.ckpt_timed,
        e.ckpt_requested - s.ckpt_requested,
        (e.ckpt_write_time - s.ckpt_write_time)::numeric,
        (e.ckpt_sync_time - s.ckpt_sync_time)::numeric,
        e.ckpt_buffers - s.ckpt_buffers,

        e.wal_bytes - s.wal_bytes,
        telemetry._pretty_bytes(e.wal_bytes - s.wal_bytes),
        (e.wal_write_time - s.wal_write_time)::numeric,
        (e.wal_sync_time - s.wal_sync_time)::numeric,

        e.bgw_buffers_clean - s.bgw_buffers_clean,
        e.bgw_buffers_alloc - s.bgw_buffers_alloc,
        e.bgw_buffers_backend - s.bgw_buffers_backend,
        e.bgw_buffers_backend_fsync - s.bgw_buffers_backend_fsync,

        e.slots_count,
        e.slots_max_retained_wal,
        telemetry._pretty_bytes(e.slots_max_retained_wal),

        e.io_checkpointer_writes - s.io_checkpointer_writes,
        (e.io_checkpointer_write_time - s.io_checkpointer_write_time)::numeric,
        e.io_checkpointer_fsyncs - s.io_checkpointer_fsyncs,
        (e.io_checkpointer_fsync_time - s.io_checkpointer_fsync_time)::numeric,
        e.io_autovacuum_writes - s.io_autovacuum_writes,
        (e.io_autovacuum_write_time - s.io_autovacuum_write_time)::numeric,
        e.io_client_writes - s.io_client_writes,
        (e.io_client_write_time - s.io_client_write_time)::numeric,
        e.io_bgwriter_writes - s.io_bgwriter_writes,
        (e.io_bgwriter_write_time - s.io_bgwriter_write_time)::numeric,

        e.temp_files - s.temp_files,
        e.temp_bytes - s.temp_bytes,
        telemetry._pretty_bytes(e.temp_bytes - s.temp_bytes)
    FROM start_snap s, end_snap e
$$;

-- -----------------------------------------------------------------------------
-- telemetry.table_deltas - View showing deltas for tracked tables
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW telemetry.table_deltas AS
SELECT
    ts.snapshot_id,
    s.captured_at,
    ts.schemaname,
    ts.relname,
    EXTRACT(EPOCH FROM (s.captured_at - prev_s.captured_at))::numeric AS interval_seconds,

    -- Size changes
    ts.pg_relation_size - prev_ts.pg_relation_size AS size_delta_bytes,
    telemetry._pretty_bytes(ts.pg_relation_size - prev_ts.pg_relation_size) AS size_delta_pretty,
    ts.pg_total_relation_size - prev_ts.pg_total_relation_size AS total_size_delta_bytes,

    -- Tuple counts (point-in-time)
    ts.n_live_tup,
    ts.n_dead_tup,
    ts.n_dead_tup::float / NULLIF(ts.n_live_tup, 0) AS dead_tuple_ratio,

    -- DML deltas
    ts.n_tup_ins - prev_ts.n_tup_ins AS inserts_delta,
    ts.n_tup_upd - prev_ts.n_tup_upd AS updates_delta,
    ts.n_tup_del - prev_ts.n_tup_del AS deletes_delta,
    ts.n_tup_hot_upd - prev_ts.n_tup_hot_upd AS hot_updates_delta,

    -- Vacuum/analyze activity
    (ts.last_autovacuum IS DISTINCT FROM prev_ts.last_autovacuum) AS autovacuum_ran,
    (ts.last_autoanalyze IS DISTINCT FROM prev_ts.last_autoanalyze) AS autoanalyze_ran,
    ts.autovacuum_count - prev_ts.autovacuum_count AS autovacuum_count_delta,
    ts.autoanalyze_count - prev_ts.autoanalyze_count AS autoanalyze_count_delta,
    ts.last_autovacuum,
    ts.last_autoanalyze

FROM telemetry.table_snapshots ts
JOIN telemetry.snapshots s ON s.id = ts.snapshot_id
JOIN telemetry.table_snapshots prev_ts ON (
    prev_ts.relid = ts.relid AND
    prev_ts.snapshot_id = (
        SELECT MAX(snapshot_id) FROM telemetry.table_snapshots
        WHERE relid = ts.relid AND snapshot_id < ts.snapshot_id
    )
)
JOIN telemetry.snapshots prev_s ON prev_s.id = prev_ts.snapshot_id
ORDER BY s.captured_at DESC, ts.relname;

-- -----------------------------------------------------------------------------
-- telemetry.recent_waits - View of wait events from last 2 hours
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW telemetry.recent_waits AS
SELECT
    sm.captured_at,
    w.backend_type,
    w.wait_event_type,
    w.wait_event,
    w.state,
    w.count
FROM telemetry.samples sm
JOIN telemetry.wait_samples w ON w.sample_id = sm.id
WHERE sm.captured_at > now() - interval '2 hours'
ORDER BY sm.captured_at DESC, w.count DESC;

-- -----------------------------------------------------------------------------
-- telemetry.recent_activity - View of active sessions from last 2 hours
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW telemetry.recent_activity AS
SELECT
    sm.captured_at,
    a.pid,
    a.usename,
    a.application_name,
    a.backend_type,
    a.state,
    a.wait_event_type,
    a.wait_event,
    a.query_start,
    sm.captured_at - a.query_start AS running_for,
    a.query_preview
FROM telemetry.samples sm
JOIN telemetry.activity_samples a ON a.sample_id = sm.id
WHERE sm.captured_at > now() - interval '2 hours'
ORDER BY sm.captured_at DESC, a.query_start ASC;

-- -----------------------------------------------------------------------------
-- telemetry.recent_locks - View of lock contention from last 2 hours
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW telemetry.recent_locks AS
SELECT
    sm.captured_at,
    l.blocked_pid,
    l.blocked_user,
    l.blocked_app,
    l.blocked_duration,
    l.blocking_pid,
    l.blocking_user,
    l.blocking_app,
    l.lock_type,
    l.locked_relation,
    l.blocked_query_preview,
    l.blocking_query_preview
FROM telemetry.samples sm
JOIN telemetry.lock_samples l ON l.sample_id = sm.id
WHERE sm.captured_at > now() - interval '2 hours'
ORDER BY sm.captured_at DESC, l.blocked_duration DESC;

-- -----------------------------------------------------------------------------
-- telemetry.recent_progress - View of operation progress from last 2 hours
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW telemetry.recent_progress AS
SELECT
    sm.captured_at,
    p.progress_type,
    p.pid,
    p.relname,
    p.phase,
    p.blocks_done,
    p.blocks_total,
    CASE WHEN p.blocks_total > 0
        THEN round(100.0 * p.blocks_done / p.blocks_total, 1)
        ELSE NULL END AS blocks_pct,
    p.tuples_done,
    p.tuples_total,
    p.bytes_done,
    p.bytes_total,
    telemetry._pretty_bytes(p.bytes_done) AS bytes_done_pretty,
    p.details
FROM telemetry.samples sm
JOIN telemetry.progress_samples p ON p.sample_id = sm.id
WHERE sm.captured_at > now() - interval '2 hours'
ORDER BY sm.captured_at DESC, p.progress_type, p.relname;

-- -----------------------------------------------------------------------------
-- telemetry.recent_replication - View of replication lag from last 2 hours
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW telemetry.recent_replication AS
SELECT
    sn.captured_at,
    r.pid,
    r.client_addr,
    r.application_name,
    r.state,
    r.sync_state,
    r.sent_lsn,
    r.write_lsn,
    r.flush_lsn,
    r.replay_lsn,
    -- Calculate lag in bytes from current WAL position at snapshot time
    pg_wal_lsn_diff(r.sent_lsn, r.replay_lsn)::bigint AS replay_lag_bytes,
    telemetry._pretty_bytes(pg_wal_lsn_diff(r.sent_lsn, r.replay_lsn)::bigint) AS replay_lag_pretty,
    r.write_lag,
    r.flush_lag,
    r.replay_lag
FROM telemetry.snapshots sn
JOIN telemetry.replication_snapshots r ON r.snapshot_id = sn.id
WHERE sn.captured_at > now() - interval '2 hours'
ORDER BY sn.captured_at DESC, r.application_name;

-- -----------------------------------------------------------------------------
-- telemetry.wait_summary() - Aggregate wait events over a time period
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.wait_summary(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    backend_type        TEXT,
    wait_event_type     TEXT,
    wait_event          TEXT,
    sample_count        BIGINT,
    total_waiters       BIGINT,
    avg_waiters         NUMERIC,
    max_waiters         INTEGER,
    pct_of_samples      NUMERIC
)
LANGUAGE sql STABLE AS $$
    WITH sample_range AS (
        SELECT id, captured_at
        FROM telemetry.samples
        WHERE captured_at BETWEEN p_start_time AND p_end_time
    ),
    total_samples AS (
        SELECT count(*) AS cnt FROM sample_range
    )
    SELECT
        w.backend_type,
        w.wait_event_type,
        w.wait_event,
        count(DISTINCT w.sample_id) AS sample_count,
        sum(w.count) AS total_waiters,
        round(avg(w.count), 2) AS avg_waiters,
        max(w.count) AS max_waiters,
        round(100.0 * count(DISTINCT w.sample_id) / NULLIF(t.cnt, 0), 1) AS pct_of_samples
    FROM telemetry.wait_samples w
    JOIN sample_range sr ON sr.id = w.sample_id
    CROSS JOIN total_samples t
    WHERE w.state NOT IN ('idle', 'idle in transaction')
    GROUP BY w.backend_type, w.wait_event_type, w.wait_event, t.cnt
    ORDER BY total_waiters DESC, sample_count DESC;
$$;

-- -----------------------------------------------------------------------------
-- telemetry.table_compare() - Compare table stats between two time points
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.table_compare(
    p_table TEXT,
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ,
    p_schema TEXT DEFAULT 'public'
)
RETURNS TABLE(
    table_name              TEXT,
    start_snapshot_at       TIMESTAMPTZ,
    end_snapshot_at         TIMESTAMPTZ,
    elapsed_seconds         NUMERIC,

    size_start              TEXT,
    size_end                TEXT,
    size_delta              TEXT,
    total_size_delta        TEXT,

    n_live_tup_start        BIGINT,
    n_live_tup_end          BIGINT,
    n_dead_tup_end          BIGINT,
    dead_tuple_ratio        NUMERIC,

    inserts_delta           BIGINT,
    updates_delta           BIGINT,
    deletes_delta           BIGINT,
    hot_updates_delta       BIGINT,

    autovacuum_ran          BOOLEAN,
    autoanalyze_ran         BOOLEAN,
    autovacuum_count_delta  BIGINT,
    autoanalyze_count_delta BIGINT
)
LANGUAGE sql STABLE AS $$
    WITH
    start_snap AS (
        SELECT ts.*, s.captured_at
        FROM telemetry.table_snapshots ts
        JOIN telemetry.snapshots s ON s.id = ts.snapshot_id
        WHERE ts.schemaname = p_schema
          AND ts.relname = p_table
          AND s.captured_at <= p_start_time
        ORDER BY s.captured_at DESC
        LIMIT 1
    ),
    end_snap AS (
        SELECT ts.*, s.captured_at
        FROM telemetry.table_snapshots ts
        JOIN telemetry.snapshots s ON s.id = ts.snapshot_id
        WHERE ts.schemaname = p_schema
          AND ts.relname = p_table
          AND s.captured_at >= p_end_time
        ORDER BY s.captured_at ASC
        LIMIT 1
    )
    SELECT
        p_schema || '.' || p_table,
        s.captured_at,
        e.captured_at,
        EXTRACT(EPOCH FROM (e.captured_at - s.captured_at))::numeric,

        telemetry._pretty_bytes(s.pg_relation_size),
        telemetry._pretty_bytes(e.pg_relation_size),
        telemetry._pretty_bytes(e.pg_relation_size - s.pg_relation_size),
        telemetry._pretty_bytes(e.pg_total_relation_size - s.pg_total_relation_size),

        s.n_live_tup,
        e.n_live_tup,
        e.n_dead_tup,
        round(e.n_dead_tup::numeric / NULLIF(e.n_live_tup, 0), 4),

        e.n_tup_ins - s.n_tup_ins,
        e.n_tup_upd - s.n_tup_upd,
        e.n_tup_del - s.n_tup_del,
        e.n_tup_hot_upd - s.n_tup_hot_upd,

        (s.last_autovacuum IS DISTINCT FROM e.last_autovacuum),
        (s.last_autoanalyze IS DISTINCT FROM e.last_autoanalyze),
        e.autovacuum_count - s.autovacuum_count,
        e.autoanalyze_count - s.autoanalyze_count
    FROM start_snap s, end_snap e
$$;

-- -----------------------------------------------------------------------------
-- telemetry.statement_compare() - Compare query stats between two time points
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.statement_compare(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ,
    p_min_delta_ms DOUBLE PRECISION DEFAULT 100,
    p_limit INTEGER DEFAULT 25
)
RETURNS TABLE(
    queryid                     BIGINT,
    query_preview               TEXT,

    calls_start                 BIGINT,
    calls_end                   BIGINT,
    calls_delta                 BIGINT,

    total_exec_time_start_ms    DOUBLE PRECISION,
    total_exec_time_end_ms      DOUBLE PRECISION,
    total_exec_time_delta_ms    DOUBLE PRECISION,

    mean_exec_time_start_ms     DOUBLE PRECISION,
    mean_exec_time_end_ms       DOUBLE PRECISION,

    rows_delta                  BIGINT,

    shared_blks_hit_delta       BIGINT,
    shared_blks_read_delta      BIGINT,
    shared_blks_written_delta   BIGINT,

    temp_blks_read_delta        BIGINT,
    temp_blks_written_delta     BIGINT,

    wal_bytes_delta             NUMERIC,

    hit_ratio_pct               NUMERIC,
    time_per_call_ms            DOUBLE PRECISION
)
LANGUAGE sql STABLE AS $$
    WITH
    start_snap AS (
        SELECT ss.*, s.captured_at
        FROM telemetry.statement_snapshots ss
        JOIN telemetry.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at <= p_start_time
        ORDER BY s.captured_at DESC
        LIMIT 1000
    ),
    end_snap AS (
        SELECT ss.*, s.captured_at
        FROM telemetry.statement_snapshots ss
        JOIN telemetry.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at >= p_end_time
        ORDER BY s.captured_at ASC
        LIMIT 1000
    ),
    matched AS (
        SELECT
            e.queryid,
            COALESCE(e.query_preview, s.query_preview) AS query_preview,

            s.calls AS calls_start,
            e.calls AS calls_end,

            s.total_exec_time AS total_exec_time_start,
            e.total_exec_time AS total_exec_time_end,

            s.mean_exec_time AS mean_exec_time_start,
            e.mean_exec_time AS mean_exec_time_end,

            s.rows AS rows_start,
            e.rows AS rows_end,

            s.shared_blks_hit AS shared_blks_hit_start,
            e.shared_blks_hit AS shared_blks_hit_end,

            s.shared_blks_read AS shared_blks_read_start,
            e.shared_blks_read AS shared_blks_read_end,

            s.shared_blks_written AS shared_blks_written_start,
            e.shared_blks_written AS shared_blks_written_end,

            s.temp_blks_read AS temp_blks_read_start,
            e.temp_blks_read AS temp_blks_read_end,

            s.temp_blks_written AS temp_blks_written_start,
            e.temp_blks_written AS temp_blks_written_end,

            s.wal_bytes AS wal_bytes_start,
            e.wal_bytes AS wal_bytes_end
        FROM end_snap e
        LEFT JOIN start_snap s ON s.queryid = e.queryid AND s.dbid = e.dbid
    )
    SELECT
        m.queryid,
        m.query_preview,

        COALESCE(m.calls_start, 0),
        m.calls_end,
        m.calls_end - COALESCE(m.calls_start, 0),

        COALESCE(m.total_exec_time_start, 0),
        m.total_exec_time_end,
        m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0),

        m.mean_exec_time_start,
        m.mean_exec_time_end,

        m.rows_end - COALESCE(m.rows_start, 0),

        m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0),
        m.shared_blks_read_end - COALESCE(m.shared_blks_read_start, 0),
        m.shared_blks_written_end - COALESCE(m.shared_blks_written_start, 0),

        m.temp_blks_read_end - COALESCE(m.temp_blks_read_start, 0),
        m.temp_blks_written_end - COALESCE(m.temp_blks_written_start, 0),

        m.wal_bytes_end - COALESCE(m.wal_bytes_start, 0),

        CASE
            WHEN (m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0) +
                  m.shared_blks_read_end - COALESCE(m.shared_blks_read_start, 0)) > 0
            THEN round(
                100.0 * (m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0)) /
                (m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0) +
                 m.shared_blks_read_end - COALESCE(m.shared_blks_read_start, 0)), 1
            )
            ELSE NULL
        END,

        CASE
            WHEN (m.calls_end - COALESCE(m.calls_start, 0)) > 0
            THEN (m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0)) /
                 (m.calls_end - COALESCE(m.calls_start, 0))
            ELSE NULL
        END

    FROM matched m
    WHERE (m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0)) >= p_min_delta_ms
    ORDER BY (m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0)) DESC
    LIMIT p_limit
$$;

-- -----------------------------------------------------------------------------
-- telemetry.activity_at() - Show what was happening at a specific moment
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.activity_at(p_timestamp TIMESTAMPTZ)
RETURNS TABLE(
    sample_captured_at      TIMESTAMPTZ,
    sample_offset_seconds   NUMERIC,

    active_sessions         INTEGER,
    waiting_sessions        INTEGER,
    idle_in_transaction     INTEGER,

    top_wait_event_1        TEXT,
    top_wait_count_1        INTEGER,
    top_wait_event_2        TEXT,
    top_wait_count_2        INTEGER,
    top_wait_event_3        TEXT,
    top_wait_count_3        INTEGER,

    blocked_pids            INTEGER,
    longest_blocked_duration INTERVAL,

    vacuums_running         INTEGER,
    copies_running          INTEGER,
    indexes_building        INTEGER,
    analyzes_running        INTEGER,

    snapshot_captured_at    TIMESTAMPTZ,
    snapshot_offset_seconds NUMERIC,
    autovacuum_workers      INTEGER,
    checkpoint_occurred     BOOLEAN
)
LANGUAGE sql STABLE AS $$
    WITH
    nearest_sample AS (
        SELECT id, captured_at,
               ABS(EXTRACT(EPOCH FROM (captured_at - p_timestamp))) AS offset_secs
        FROM telemetry.samples
        ORDER BY ABS(EXTRACT(EPOCH FROM (captured_at - p_timestamp)))
        LIMIT 1
    ),
    nearest_snapshot AS (
        SELECT s.id, s.captured_at, s.autovacuum_workers,
               (s.checkpoint_time IS DISTINCT FROM prev.checkpoint_time) AS checkpoint_occurred,
               ABS(EXTRACT(EPOCH FROM (s.captured_at - p_timestamp))) AS offset_secs
        FROM telemetry.snapshots s
        LEFT JOIN telemetry.snapshots prev ON prev.id = (
            SELECT MAX(id) FROM telemetry.snapshots WHERE id < s.id
        )
        ORDER BY ABS(EXTRACT(EPOCH FROM (s.captured_at - p_timestamp)))
        LIMIT 1
    ),
    sample_waits AS (
        SELECT
            wait_event_type || ':' || wait_event AS wait_event,
            count
        FROM telemetry.wait_samples w
        JOIN nearest_sample ns ON ns.id = w.sample_id
        WHERE w.state NOT IN ('idle', 'idle in transaction')
        ORDER BY count DESC
        LIMIT 3
    ),
    wait_array AS (
        SELECT array_agg(wait_event ORDER BY count DESC) AS events,
               array_agg(count ORDER BY count DESC) AS counts
        FROM sample_waits
    ),
    sample_activity AS (
        SELECT
            count(*) FILTER (WHERE state = 'active') AS active_sessions,
            count(*) FILTER (WHERE wait_event IS NOT NULL) AS waiting_sessions,
            count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction
        FROM telemetry.activity_samples a
        JOIN nearest_sample ns ON ns.id = a.sample_id
    ),
    sample_locks AS (
        SELECT
            count(DISTINCT blocked_pid) AS blocked_pids,
            max(blocked_duration) AS longest_blocked
        FROM telemetry.lock_samples l
        JOIN nearest_sample ns ON ns.id = l.sample_id
    ),
    sample_progress AS (
        SELECT
            count(*) FILTER (WHERE progress_type = 'vacuum') AS vacuums,
            count(*) FILTER (WHERE progress_type = 'copy') AS copies,
            count(*) FILTER (WHERE progress_type = 'create_index') AS indexes,
            count(*) FILTER (WHERE progress_type = 'analyze') AS analyzes
        FROM telemetry.progress_samples p
        JOIN nearest_sample ns ON ns.id = p.sample_id
    )
    SELECT
        ns.captured_at,
        ns.offset_secs::numeric,

        COALESCE(sa.active_sessions, 0)::integer,
        COALESCE(sa.waiting_sessions, 0)::integer,
        COALESCE(sa.idle_in_transaction, 0)::integer,

        wa.events[1],
        wa.counts[1],
        wa.events[2],
        wa.counts[2],
        wa.events[3],
        wa.counts[3],

        COALESCE(sl.blocked_pids, 0)::integer,
        sl.longest_blocked,

        COALESCE(sp.vacuums, 0)::integer,
        COALESCE(sp.copies, 0)::integer,
        COALESCE(sp.indexes, 0)::integer,
        COALESCE(sp.analyzes, 0)::integer,

        sn.captured_at,
        sn.offset_secs::numeric,
        sn.autovacuum_workers,
        sn.checkpoint_occurred
    FROM nearest_sample ns
    CROSS JOIN nearest_snapshot sn
    CROSS JOIN sample_activity sa
    CROSS JOIN sample_locks sl
    CROSS JOIN sample_progress sp
    CROSS JOIN wait_array wa
$$;

-- -----------------------------------------------------------------------------
-- telemetry.anomaly_report() - Flag unusual patterns in a time window
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.anomaly_report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    anomaly_type        TEXT,
    severity            TEXT,
    description         TEXT,
    metric_value        TEXT,
    threshold           TEXT,
    recommendation      TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cmp RECORD;
    v_wait_pct NUMERIC;
    v_lock_count INTEGER;
    v_max_block_duration INTERVAL;
BEGIN
    -- Get comparison data
    SELECT * INTO v_cmp FROM telemetry.compare(p_start_time, p_end_time);

    -- Check 1: Checkpoint occurred during window
    IF v_cmp.checkpoint_occurred THEN
        anomaly_type := 'CHECKPOINT_DURING_WINDOW';
        severity := CASE
            WHEN v_cmp.ckpt_write_time_ms > 30000 THEN 'high'
            WHEN v_cmp.ckpt_write_time_ms > 10000 THEN 'medium'
            ELSE 'low'
        END;
        description := 'A checkpoint occurred during this time window';
        metric_value := format('write_time: %s ms, sync_time: %s ms',
                              round(v_cmp.ckpt_write_time_ms::numeric, 1),
                              round(v_cmp.ckpt_sync_time_ms::numeric, 1));
        threshold := 'Any checkpoint';
        recommendation := 'Consider increasing max_wal_size or scheduling heavy writes after checkpoint_timeout';
        RETURN NEXT;
    END IF;

    -- Check 2: Forced checkpoint (ckpt_requested)
    IF v_cmp.ckpt_requested_delta > 0 THEN
        anomaly_type := 'FORCED_CHECKPOINT';
        severity := 'high';
        description := 'WAL exceeded max_wal_size, forcing checkpoint';
        metric_value := format('%s forced checkpoints', v_cmp.ckpt_requested_delta);
        threshold := 'ckpt_requested_delta > 0';
        recommendation := 'Increase max_wal_size to prevent mid-batch checkpoints';
        RETURN NEXT;
    END IF;

    -- Check 3: Backend buffer writes (shared_buffers pressure)
    IF COALESCE(v_cmp.bgw_buffers_backend_delta, 0) > 0 THEN
        anomaly_type := 'BUFFER_PRESSURE';
        severity := CASE
            WHEN v_cmp.bgw_buffers_backend_delta > 1000 THEN 'high'
            WHEN v_cmp.bgw_buffers_backend_delta > 100 THEN 'medium'
            ELSE 'low'
        END;
        description := 'Backends forced to write buffers directly (shared_buffers exhaustion)';
        metric_value := format('%s backend buffer writes', v_cmp.bgw_buffers_backend_delta);
        threshold := 'bgw_buffers_backend_delta > 0';
        recommendation := 'Increase shared_buffers, reduce concurrent writers, or use faster storage';
        RETURN NEXT;
    END IF;

    -- Check 4: Backend fsync (very bad)
    IF COALESCE(v_cmp.bgw_buffers_backend_fsync_delta, 0) > 0 THEN
        anomaly_type := 'BACKEND_FSYNC';
        severity := 'high';
        description := 'Backends forced to perform fsync (severe I/O bottleneck)';
        metric_value := format('%s backend fsyncs', v_cmp.bgw_buffers_backend_fsync_delta);
        threshold := 'bgw_buffers_backend_fsync_delta > 0';
        recommendation := 'Urgent: increase shared_buffers, reduce write load, or upgrade storage';
        RETURN NEXT;
    END IF;

    -- Check 5: Temp file spills
    IF COALESCE(v_cmp.temp_files_delta, 0) > 0 THEN
        anomaly_type := 'TEMP_FILE_SPILLS';
        severity := CASE
            WHEN v_cmp.temp_bytes_delta > 1073741824 THEN 'high'
            WHEN v_cmp.temp_bytes_delta > 104857600 THEN 'medium'
            ELSE 'low'
        END;
        description := 'Queries spilling to temp files (work_mem exhaustion)';
        metric_value := format('%s temp files, %s written',
                              v_cmp.temp_files_delta, v_cmp.temp_bytes_pretty);
        threshold := 'temp_files_delta > 0';
        recommendation := 'Increase work_mem for affected sessions or globally';
        RETURN NEXT;
    END IF;

    -- Check 6: Lock contention
    SELECT count(DISTINCT blocked_pid), max(blocked_duration)
    INTO v_lock_count, v_max_block_duration
    FROM telemetry.lock_samples l
    JOIN telemetry.samples s ON s.id = l.sample_id
    WHERE s.captured_at BETWEEN p_start_time AND p_end_time;

    IF v_lock_count > 0 THEN
        anomaly_type := 'LOCK_CONTENTION';
        severity := CASE
            WHEN v_max_block_duration > interval '30 seconds' THEN 'high'
            WHEN v_max_block_duration > interval '5 seconds' THEN 'medium'
            ELSE 'low'
        END;
        description := 'Lock contention detected';
        metric_value := format('%s blocked sessions, max duration: %s',
                              v_lock_count, v_max_block_duration);
        threshold := 'Any lock contention';
        recommendation := 'Check recent_locks for blocking queries; consider shorter transactions';
        RETURN NEXT;
    END IF;

    RETURN;
END;
$$;

-- -----------------------------------------------------------------------------
-- telemetry.summary_report() - Comprehensive diagnostic summary
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.summary_report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    section             TEXT,
    metric              TEXT,
    value               TEXT,
    interpretation      TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cmp RECORD;
    v_sample_count INTEGER;
    v_anomaly_count INTEGER;
    v_top_wait RECORD;
    v_lock_summary RECORD;
BEGIN
    -- Get comparison data
    SELECT * INTO v_cmp FROM telemetry.compare(p_start_time, p_end_time);

    SELECT count(*) INTO v_sample_count
    FROM telemetry.samples WHERE captured_at BETWEEN p_start_time AND p_end_time;

    SELECT count(*) INTO v_anomaly_count
    FROM telemetry.anomaly_report(p_start_time, p_end_time);

    -- === OVERVIEW SECTION ===
    section := 'OVERVIEW';

    metric := 'Time Window';
    value := format('%s to %s', p_start_time, p_end_time);
    interpretation := format('%s seconds elapsed', round(COALESCE(v_cmp.elapsed_seconds, 0), 1));
    RETURN NEXT;

    metric := 'Data Coverage';
    value := format('%s snapshots, %s samples',
                   (SELECT count(*) FROM telemetry.snapshots
                    WHERE captured_at BETWEEN p_start_time AND p_end_time),
                   v_sample_count);
    interpretation := CASE
        WHEN v_sample_count = 0 THEN 'WARNING: No sample data in window'
        ELSE 'OK'
    END;
    RETURN NEXT;

    metric := 'Anomalies Detected';
    value := v_anomaly_count::text;
    interpretation := CASE
        WHEN v_anomaly_count = 0 THEN 'No issues detected'
        WHEN v_anomaly_count <= 2 THEN 'Minor issues'
        ELSE 'Multiple issues - review anomaly_report()'
    END;
    RETURN NEXT;

    -- === CHECKPOINT/WAL SECTION ===
    section := 'CHECKPOINT & WAL';

    metric := 'Checkpoint Occurred';
    value := COALESCE(v_cmp.checkpoint_occurred::text, 'unknown');
    interpretation := CASE
        WHEN v_cmp.checkpoint_occurred THEN
            format('Checkpoint write: %s ms', round(COALESCE(v_cmp.ckpt_write_time_ms, 0)::numeric, 1))
        ELSE 'No checkpoint during window'
    END;
    RETURN NEXT;

    metric := 'WAL Generated';
    value := COALESCE(v_cmp.wal_bytes_pretty, 'N/A');
    interpretation := format('%s MB/sec',
                            round((COALESCE(v_cmp.wal_bytes_delta, 0) / 1048576.0) / NULLIF(v_cmp.elapsed_seconds, 0), 2));
    RETURN NEXT;

    -- === BUFFER SECTION ===
    section := 'BUFFERS & I/O';

    metric := 'Buffers Allocated';
    value := COALESCE(v_cmp.bgw_buffers_alloc_delta::text, 'N/A');
    interpretation := 'New buffer allocations';
    RETURN NEXT;

    metric := 'Backend Buffer Writes';
    value := COALESCE(v_cmp.bgw_buffers_backend_delta::text, 'N/A');
    interpretation := CASE
        WHEN COALESCE(v_cmp.bgw_buffers_backend_delta, 0) > 0 THEN 'WARNING: Backends writing directly'
        ELSE 'OK'
    END;
    RETURN NEXT;

    metric := 'Temp File Spills';
    value := format('%s files, %s', COALESCE(v_cmp.temp_files_delta, 0), COALESCE(v_cmp.temp_bytes_pretty, '0 B'));
    interpretation := CASE
        WHEN COALESCE(v_cmp.temp_files_delta, 0) > 0 THEN 'Consider increasing work_mem'
        ELSE 'No temp file usage'
    END;
    RETURN NEXT;

    -- === WAIT EVENTS SECTION ===
    section := 'WAIT EVENTS';

    FOR v_top_wait IN
        SELECT wait_event_type || ':' || wait_event AS we, total_waiters, pct_of_samples
        FROM telemetry.wait_summary(p_start_time, p_end_time)
        LIMIT 5
    LOOP
        metric := v_top_wait.we;
        value := format('%s total waiters (%s%% of samples)',
                       v_top_wait.total_waiters, v_top_wait.pct_of_samples);
        interpretation := CASE
            WHEN v_top_wait.we LIKE 'Lock:%' THEN 'Lock contention'
            WHEN v_top_wait.we LIKE 'LWLock:Buffer%' THEN 'Buffer contention'
            WHEN v_top_wait.we LIKE 'LWLock:WAL%' THEN 'WAL contention'
            WHEN v_top_wait.we LIKE 'IO:%' THEN 'I/O bound'
            WHEN v_top_wait.we = 'Running:CPU' THEN 'CPU active (normal)'
            ELSE 'Review PostgreSQL docs'
        END;
        RETURN NEXT;
    END LOOP;

    -- === LOCK SECTION ===
    section := 'LOCK CONTENTION';

    SELECT
        count(DISTINCT blocked_pid) AS blocked_count,
        max(blocked_duration) AS max_duration
    INTO v_lock_summary
    FROM telemetry.lock_samples l
    JOIN telemetry.samples s ON s.id = l.sample_id
    WHERE s.captured_at BETWEEN p_start_time AND p_end_time;

    metric := 'Blocked Sessions';
    value := COALESCE(v_lock_summary.blocked_count, 0)::text;
    interpretation := CASE
        WHEN COALESCE(v_lock_summary.blocked_count, 0) = 0 THEN 'No lock contention'
        ELSE format('Max blocked duration: %s', v_lock_summary.max_duration)
    END;
    RETURN NEXT;

    RETURN;
END;
$$;

-- -----------------------------------------------------------------------------
-- telemetry.set_mode() - Configure telemetry collection mode
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.set_mode(p_mode TEXT)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_interval TEXT;
    v_enable_locks BOOLEAN;
    v_enable_progress BOOLEAN;
    v_description TEXT;
    v_pgcron_version TEXT;
    v_supports_subsecond BOOLEAN := FALSE;
BEGIN
    -- Validate mode
    IF p_mode NOT IN ('normal', 'light', 'emergency') THEN
        RAISE EXCEPTION 'Invalid mode: %. Must be normal, light, or emergency.', p_mode;
    END IF;

    -- Set mode-specific configuration
    CASE p_mode
        WHEN 'normal' THEN
            v_interval := '30 seconds';
            v_enable_locks := TRUE;
            v_enable_progress := TRUE;
            v_description := 'Normal mode: 30s sampling, all collectors enabled';
        WHEN 'light' THEN
            v_interval := '* * * * *';  -- Every minute (cron format for 60s)
            v_enable_locks := TRUE;
            v_enable_progress := FALSE;
            v_description := 'Light mode: 60s sampling, progress tracking disabled';
        WHEN 'emergency' THEN
            v_interval := '*/2 * * * *';  -- Every 2 minutes (cron format for 120s)
            v_enable_locks := FALSE;
            v_enable_progress := FALSE;
            v_description := 'Emergency mode: 120s sampling, locks and progress disabled';
    END CASE;

    -- Update configuration
    INSERT INTO telemetry.config (key, value, updated_at)
    VALUES ('mode', p_mode, now())
    ON CONFLICT (key) DO UPDATE SET value = p_mode, updated_at = now();

    INSERT INTO telemetry.config (key, value, updated_at)
    VALUES ('enable_locks', v_enable_locks::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_enable_locks::text, updated_at = now();

    INSERT INTO telemetry.config (key, value, updated_at)
    VALUES ('enable_progress', v_enable_progress::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_enable_progress::text, updated_at = now();

    -- Reschedule pg_cron job (if pg_cron available)
    BEGIN
        SELECT extversion INTO v_pgcron_version FROM pg_extension WHERE extname = 'pg_cron';

        IF v_pgcron_version IS NOT NULL THEN
            v_pgcron_version := split_part(v_pgcron_version, '-', 1);
            v_supports_subsecond := (
                split_part(v_pgcron_version, '.', 1)::int > 1 OR
                (split_part(v_pgcron_version, '.', 1)::int = 1 AND
                 split_part(v_pgcron_version, '.', 2)::int > 4) OR
                (split_part(v_pgcron_version, '.', 1)::int = 1 AND
                 split_part(v_pgcron_version, '.', 2)::int = 4 AND
                 COALESCE(NULLIF(split_part(v_pgcron_version, '.', 3), '')::int, 0) >= 1)
            );

            -- Unschedule existing
            PERFORM cron.unschedule('telemetry_sample');

            IF v_supports_subsecond THEN
                PERFORM cron.schedule('telemetry_sample', v_interval, 'SELECT telemetry.sample()');
            ELSE
                -- Fallback: minute-level schedules
                IF p_mode = 'emergency' THEN
                    PERFORM cron.schedule('telemetry_sample', '*/2 * * * *', 'SELECT telemetry.sample()');
                ELSE
                    PERFORM cron.schedule('telemetry_sample', '* * * * *', 'SELECT telemetry.sample()');
                END IF;
            END IF;
        END IF;
    EXCEPTION
        WHEN undefined_table THEN NULL;
        WHEN undefined_function THEN NULL;
    END;

    RETURN v_description;
END;
$$;

-- -----------------------------------------------------------------------------
-- telemetry.get_mode() - Show current telemetry configuration
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.get_mode()
RETURNS TABLE(
    mode                TEXT,
    sample_interval     TEXT,
    locks_enabled       BOOLEAN,
    progress_enabled    BOOLEAN,
    statements_enabled  TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        telemetry._get_config('mode', 'normal') AS mode,
        CASE telemetry._get_config('mode', 'normal')
            WHEN 'normal' THEN '30 seconds'
            WHEN 'light' THEN '60 seconds'
            WHEN 'emergency' THEN '120 seconds'
            ELSE 'unknown'
        END AS sample_interval,
        COALESCE(telemetry._get_config('enable_locks', 'true')::boolean, true) AS locks_enabled,
        COALESCE(telemetry._get_config('enable_progress', 'true')::boolean, true) AS progress_enabled,
        telemetry._get_config('statements_enabled', 'auto') AS statements_enabled
$$;

-- -----------------------------------------------------------------------------
-- telemetry.cleanup() - Remove old telemetry data
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION telemetry.cleanup(p_retain_interval INTERVAL DEFAULT '7 days')
RETURNS TABLE(
    deleted_snapshots   BIGINT,
    deleted_samples     BIGINT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_deleted_snapshots BIGINT;
    v_deleted_samples BIGINT;
    v_cutoff TIMESTAMPTZ := now() - p_retain_interval;
BEGIN
    -- Delete old samples (cascades to wait_samples, activity_samples, progress_samples, lock_samples)
    WITH deleted AS (
        DELETE FROM telemetry.samples WHERE captured_at < v_cutoff RETURNING 1
    )
    SELECT count(*) INTO v_deleted_samples FROM deleted;

    -- Delete old snapshots (cascades to table_snapshots, replication_snapshots)
    WITH deleted AS (
        DELETE FROM telemetry.snapshots WHERE captured_at < v_cutoff RETURNING 1
    )
    SELECT count(*) INTO v_deleted_snapshots FROM deleted;

    RETURN QUERY SELECT v_deleted_snapshots, v_deleted_samples;
END;
$$;

-- -----------------------------------------------------------------------------
-- Schedule snapshot collection via pg_cron (every 5 minutes)
-- Schedule sample collection via pg_cron (every 30 seconds)
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_pgcron_version TEXT;
    v_major INT;
    v_minor INT;
    v_patch INT;
    v_supports_subsecond BOOLEAN := FALSE;
    v_sample_schedule TEXT;
BEGIN
    -- Remove existing jobs if any
    BEGIN
        PERFORM cron.unschedule('telemetry_snapshot')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'telemetry_snapshot');
        PERFORM cron.unschedule('telemetry_sample')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'telemetry_sample');
        PERFORM cron.unschedule('telemetry_cleanup')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'telemetry_cleanup');
    EXCEPTION
        WHEN undefined_table THEN NULL;
        WHEN undefined_function THEN NULL;
    END;

    -- Check pg_cron version to determine if sub-minute scheduling is supported
    -- Sub-minute intervals (e.g., '30 seconds') require pg_cron 1.4.1+
    SELECT extversion INTO v_pgcron_version
    FROM pg_extension WHERE extname = 'pg_cron';

    IF v_pgcron_version IS NOT NULL THEN
        -- Parse version string (handles "1.4.1", "1.4-1", "1.4.1-1", etc.)
        -- Extract numeric parts, treating "-" as a package revision separator (not a version component)
        v_pgcron_version := split_part(v_pgcron_version, '-', 1);  -- Strip package revision (e.g., "1.4-1" -> "1.4")
        v_major := COALESCE(split_part(v_pgcron_version, '.', 1)::int, 0);
        v_minor := COALESCE(NULLIF(split_part(v_pgcron_version, '.', 2), '')::int, 0);
        v_patch := COALESCE(NULLIF(split_part(v_pgcron_version, '.', 3), '')::int, 0);

        -- Check if version >= 1.4.1
        v_supports_subsecond := (v_major > 1)
            OR (v_major = 1 AND v_minor > 4)
            OR (v_major = 1 AND v_minor = 4 AND v_patch >= 1);
    END IF;

    -- Schedule snapshot collection (every 5 minutes) - works on all pg_cron versions
    PERFORM cron.schedule(
        'telemetry_snapshot',
        '*/5 * * * *',
        'SELECT telemetry.snapshot()'
    );

    -- Schedule sample collection based on pg_cron capabilities
    IF v_supports_subsecond THEN
        v_sample_schedule := '30 seconds';
        PERFORM cron.schedule(
            'telemetry_sample',
            '30 seconds',
            'SELECT telemetry.sample()'
        );
        RAISE NOTICE 'pg_cron % supports sub-minute scheduling. Sampling every 30 seconds.', v_pgcron_version;
    ELSE
        v_sample_schedule := '* * * * * (every minute)';
        PERFORM cron.schedule(
            'telemetry_sample',
            '* * * * *',
            'SELECT telemetry.sample()'
        );
        RAISE NOTICE 'pg_cron % does not support sub-minute scheduling (requires 1.4.1+). Sampling every minute instead.', v_pgcron_version;
    END IF;

    -- Schedule cleanup (daily at 3 AM, retain 7 days)
    PERFORM cron.schedule(
        'telemetry_cleanup',
        '0 3 * * *',
        'SELECT * FROM telemetry.cleanup(''7 days''::interval)'
    );

EXCEPTION
    WHEN undefined_table THEN
        RAISE NOTICE 'pg_cron extension not found. Automatic scheduling disabled. Run telemetry.snapshot() and telemetry.sample() manually or via external scheduler.';
    WHEN undefined_function THEN
        RAISE NOTICE 'pg_cron extension not found. Automatic scheduling disabled. Run telemetry.snapshot() and telemetry.sample() manually or via external scheduler.';
END;
$$;

-- Capture initial snapshot and sample
SELECT telemetry.snapshot();
SELECT telemetry.sample();

-- -----------------------------------------------------------------------------
-- Done
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_sample_schedule TEXT;
BEGIN
    -- Determine what sampling schedule was configured
    SELECT schedule INTO v_sample_schedule
    FROM cron.job WHERE jobname = 'telemetry_sample';

    RAISE NOTICE '';
    RAISE NOTICE 'Telemetry installed successfully.';
    RAISE NOTICE '';
    RAISE NOTICE 'Collection schedule:';
    RAISE NOTICE '  - Snapshots: every 5 minutes (WAL, checkpoints, I/O stats)';
    RAISE NOTICE '  - Samples: % (wait events, activity, progress, locks)', COALESCE(v_sample_schedule, 'not scheduled');
    RAISE NOTICE '  - Cleanup: daily at 3 AM (retains 7 days)';
    RAISE NOTICE '';
    RAISE NOTICE 'Quick start for batch monitoring:';
    RAISE NOTICE '  1. Track your target table:';
    RAISE NOTICE '     SELECT telemetry.track_table(''my_table'');';
    RAISE NOTICE '';
    RAISE NOTICE '  2. Run your batch job, then analyze:';
    RAISE NOTICE '     SELECT * FROM telemetry.compare(''2024-12-16 14:00'', ''2024-12-16 15:00'');';
    RAISE NOTICE '     SELECT * FROM telemetry.table_compare(''my_table'', ''2024-12-16 14:00'', ''2024-12-16 15:00'');';
    RAISE NOTICE '     SELECT * FROM telemetry.wait_summary(''2024-12-16 14:00'', ''2024-12-16 15:00'');';
    RAISE NOTICE '';
    RAISE NOTICE 'Views for recent activity:';
    RAISE NOTICE '  - telemetry.deltas            (snapshot deltas incl. temp files)';
    RAISE NOTICE '  - telemetry.table_deltas      (tracked table deltas)';
    RAISE NOTICE '  - telemetry.recent_waits      (wait events, last 2 hours)';
    RAISE NOTICE '  - telemetry.recent_activity   (active sessions, last 2 hours)';
    RAISE NOTICE '  - telemetry.recent_locks      (lock contention, last 2 hours)';
    RAISE NOTICE '  - telemetry.recent_progress   (vacuum/copy/analyze progress, last 2 hours)';
    RAISE NOTICE '  - telemetry.recent_replication (replication lag, last 2 hours)';
    RAISE NOTICE '';
    RAISE NOTICE 'Table management:';
    RAISE NOTICE '  - telemetry.track_table(name, schema)';
    RAISE NOTICE '  - telemetry.untrack_table(name, schema)';
    RAISE NOTICE '  - telemetry.list_tracked_tables()';
    RAISE NOTICE '';
EXCEPTION
    WHEN undefined_table THEN
        -- pg_cron not available, show generic message
        RAISE NOTICE '';
        RAISE NOTICE 'Telemetry installed successfully.';
        RAISE NOTICE '';
        RAISE NOTICE 'NOTE: pg_cron not available. Run telemetry.snapshot() and telemetry.sample() manually.';
        RAISE NOTICE '';
END;
$$;
