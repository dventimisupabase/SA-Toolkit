-- =============================================================================
-- Uninstall Batch Telemetry
-- =============================================================================
-- Removes the cron job and all telemetry data/functions.
-- =============================================================================

-- Remove cron job first
SELECT cron.unschedule('telemetry_snapshot')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'telemetry_snapshot');

-- Drop schema and all objects
DROP SCHEMA IF EXISTS telemetry CASCADE;

DO $$
BEGIN
    RAISE NOTICE 'Telemetry removed.';
END;
$$;
