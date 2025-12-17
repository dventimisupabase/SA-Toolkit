-- =============================================================================
-- Uninstall Batch Telemetry
-- =============================================================================
-- Removes all cron jobs and telemetry data/functions.
-- Run with: psql -f uninstall.sql
-- =============================================================================

-- Remove all cron jobs first
DO $$
BEGIN
    PERFORM cron.unschedule('telemetry_snapshot')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'telemetry_snapshot');

    PERFORM cron.unschedule('telemetry_sample')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'telemetry_sample');

    PERFORM cron.unschedule('telemetry_cleanup')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'telemetry_cleanup');
EXCEPTION
    WHEN undefined_table THEN NULL;  -- cron schema doesn't exist
    WHEN undefined_function THEN NULL;  -- cron.unschedule doesn't exist
END;
$$;

-- Drop schema and all objects
DROP SCHEMA IF EXISTS telemetry CASCADE;

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE 'Telemetry uninstalled successfully.';
    RAISE NOTICE '';
    RAISE NOTICE 'Removed:';
    RAISE NOTICE '  - All telemetry tables and data';
    RAISE NOTICE '  - All telemetry functions and views';
    RAISE NOTICE '  - All scheduled cron jobs (snapshot, sample, cleanup)';
    RAISE NOTICE '';
END;
$$;
