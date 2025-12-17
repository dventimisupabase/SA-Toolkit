-- ============================================================
-- Setup Subscription (Run on STANDBY Supabase Project)
-- ============================================================
-- This script creates the subscription to receive replicated
-- data from the primary Supabase project.
--
-- Prerequisites:
--   - Publication and slot created on primary
--   - Schema deployed to standby (same migrations)
--   - Network connectivity to primary
--
-- IMPORTANT: Replace placeholders before running:
--   - <PRIMARY_HOST>: e.g., db.abcd1234.supabase.co
--   - <PASSWORD>: postgres user password
-- ============================================================

-- ============================================================
-- Pre-flight Checks
-- ============================================================

-- Verify we're on the standby (no existing subscription)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_subscription WHERE subname = 'dr_subscription') THEN
        RAISE EXCEPTION 'Subscription dr_subscription already exists. Drop it first if re-creating.';
    END IF;
END $$;

-- ============================================================
-- Create Subscription
-- ============================================================

-- IMPORTANT: Replace <PRIMARY_HOST> and <PASSWORD> with actual values!
CREATE SUBSCRIPTION dr_subscription
CONNECTION 'host=<PRIMARY_HOST> port=5432 user=postgres password=<PASSWORD> dbname=postgres'
PUBLICATION dr_publication
WITH (
    copy_data = true,           -- Initial sync of existing data
    create_slot = false,        -- We created slot on primary
    slot_name = 'dr_slot',      -- Must match slot created on primary
    synchronous_commit = off,   -- Async replication (better performance)
    connect = true              -- Connect immediately
);

-- ============================================================
-- Alternative: Parameterized Version (PostgreSQL 15+)
-- Use this in scripts with environment variable substitution
-- ============================================================
-- CREATE SUBSCRIPTION dr_subscription
-- CONNECTION :'primary_conninfo'
-- PUBLICATION dr_publication
-- WITH (
--     copy_data = true,
--     create_slot = false,
--     slot_name = 'dr_slot',
--     synchronous_commit = off
-- );

-- ============================================================
-- Verification
-- ============================================================

-- Check subscription status
SELECT
    subname,
    subenabled,
    subconninfo,
    subslotname,
    subsynccommit
FROM pg_subscription
WHERE subname = 'dr_subscription';

-- Check subscription statistics
SELECT
    subname,
    received_lsn,
    latest_end_lsn,
    last_msg_send_time,
    last_msg_receipt_time
FROM pg_stat_subscription
WHERE subname = 'dr_subscription';

-- Check table sync status
-- States: i=init, d=data copy, f=finished table copy, s=sync, r=ready
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
    END AS state_description
FROM pg_subscription_rel
WHERE srsubid = (SELECT oid FROM pg_subscription WHERE subname = 'dr_subscription');

-- ============================================================
-- Helpful Commands (for reference)
-- ============================================================

-- Pause replication:
-- ALTER SUBSCRIPTION dr_subscription DISABLE;

-- Resume replication:
-- ALTER SUBSCRIPTION dr_subscription ENABLE;

-- Refresh after adding tables to publication:
-- ALTER SUBSCRIPTION dr_subscription REFRESH PUBLICATION;

-- Drop subscription (required before failover promotion):
-- DROP SUBSCRIPTION dr_subscription;
