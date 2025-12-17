-- ============================================================
-- Pause Replication (Run on STANDBY)
-- ============================================================
-- Disables the subscription, stopping replication from primary.
-- Use before maintenance or during planned failover preparation.
-- ============================================================

-- Disable the subscription
ALTER SUBSCRIPTION dr_subscription DISABLE;

-- Verify it's disabled
SELECT
    subname,
    subenabled,
    CASE subenabled
        WHEN true THEN 'ENABLED - replication active'
        WHEN false THEN 'DISABLED - replication paused'
    END AS status
FROM pg_subscription
WHERE subname = 'dr_subscription';

-- Note: The replication slot on primary will continue to accumulate WAL.
-- Don't leave paused for extended periods or the slot will grow large.
