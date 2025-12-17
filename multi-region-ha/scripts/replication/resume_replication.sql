-- ============================================================
-- Resume Replication (Run on STANDBY)
-- ============================================================
-- Re-enables the subscription after it was paused.
-- The standby will catch up from where it left off.
-- ============================================================

-- Enable the subscription
ALTER SUBSCRIPTION dr_subscription ENABLE;

-- Verify it's enabled
SELECT
    subname,
    subenabled,
    CASE subenabled
        WHEN true THEN 'ENABLED - replication active'
        WHEN false THEN 'DISABLED - replication paused'
    END AS status
FROM pg_subscription
WHERE subname = 'dr_subscription';

-- Check catch-up progress
SELECT
    subname,
    received_lsn,
    latest_end_lsn,
    last_msg_receipt_time
FROM pg_stat_subscription
WHERE subname = 'dr_subscription';
