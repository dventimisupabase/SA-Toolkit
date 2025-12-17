-- ============================================================
-- Verify Replication Status
-- ============================================================
-- Run these queries to check replication health.
-- Some queries run on PRIMARY, others on STANDBY.
-- ============================================================

-- ============================================================
-- ON PRIMARY: Check Replication Slot
-- ============================================================

-- Slot status and lag
SELECT
    slot_name,
    plugin,
    slot_type,
    active,
    active_pid,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)
    ) AS replication_lag
FROM pg_replication_slots
WHERE slot_name = 'dr_slot';

-- Replication statistics
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_bytes,
    sync_state
FROM pg_stat_replication;

-- Publication tables
SELECT
    schemaname,
    tablename
FROM pg_publication_tables
WHERE pubname = 'dr_publication'
ORDER BY schemaname, tablename;

-- ============================================================
-- ON STANDBY: Check Subscription
-- ============================================================

-- Subscription status
SELECT
    subname,
    subenabled,
    subconninfo,
    subslotname
FROM pg_subscription
WHERE subname = 'dr_subscription';

-- Subscription statistics
SELECT
    subname,
    received_lsn,
    latest_end_lsn,
    last_msg_send_time,
    last_msg_receipt_time,
    age(now(), last_msg_receipt_time) AS time_since_last_message
FROM pg_stat_subscription
WHERE subname = 'dr_subscription';

-- Table sync status
SELECT
    srrelid::regclass AS table_name,
    srsubstate AS state,
    CASE srsubstate
        WHEN 'i' THEN 'initializing'
        WHEN 'd' THEN 'copying data'
        WHEN 'f' THEN 'finished copy'
        WHEN 's' THEN 'syncing'
        WHEN 'r' THEN 'ready'
        ELSE 'unknown'
    END AS state_description,
    srsublsn AS sync_lsn
FROM pg_subscription_rel
WHERE srsubid = (SELECT oid FROM pg_subscription WHERE subname = 'dr_subscription')
ORDER BY srrelid::regclass::text;

-- ============================================================
-- ON BOTH: Compare Row Counts
-- ============================================================
-- Run on both primary and standby, compare results

SELECT
    schemaname,
    relname AS table_name,
    n_live_tup AS row_count,
    last_vacuum,
    last_analyze
FROM pg_stat_user_tables
WHERE schemaname IN ('public', 'auth', 'storage')
ORDER BY schemaname, relname;

-- ============================================================
-- Health Check Summary (Run on PRIMARY)
-- ============================================================

SELECT
    CASE
        WHEN NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'dr_slot')
        THEN 'ERROR: Replication slot not found'
        WHEN NOT (SELECT active FROM pg_replication_slots WHERE slot_name = 'dr_slot')
        THEN 'WARNING: Replication slot not active'
        WHEN pg_wal_lsn_diff(
            pg_current_wal_lsn(),
            (SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = 'dr_slot')
        ) > 100 * 1024 * 1024  -- 100 MB
        THEN 'WARNING: Replication lag > 100 MB'
        ELSE 'OK: Replication healthy'
    END AS replication_status,
    pg_size_pretty(
        pg_wal_lsn_diff(
            pg_current_wal_lsn(),
            COALESCE(
                (SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = 'dr_slot'),
                pg_current_wal_lsn()
            )
        )
    ) AS current_lag;

-- ============================================================
-- Health Check Summary (Run on STANDBY)
-- ============================================================

SELECT
    CASE
        WHEN NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subname = 'dr_subscription')
        THEN 'ERROR: Subscription not found'
        WHEN NOT (SELECT subenabled FROM pg_subscription WHERE subname = 'dr_subscription')
        THEN 'WARNING: Subscription disabled'
        WHEN (SELECT age(now(), last_msg_receipt_time) > interval '5 minutes'
              FROM pg_stat_subscription WHERE subname = 'dr_subscription')
        THEN 'WARNING: No message received in 5+ minutes'
        ELSE 'OK: Subscription healthy'
    END AS subscription_status,
    (SELECT last_msg_receipt_time FROM pg_stat_subscription WHERE subname = 'dr_subscription')
        AS last_message_time;
