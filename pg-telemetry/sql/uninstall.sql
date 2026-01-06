-- =============================================================================
-- Uninstall pg-telemetry
-- =============================================================================
-- Removes all cron jobs and telemetry data/functions.
-- Run with: psql -f uninstall.sql
-- =============================================================================

-- Remove all cron jobs and clean up job history
DO $$
DECLARE
    v_jobids BIGINT[];
    v_deleted_count INTEGER;
BEGIN
    -- Collect job IDs before unscheduling
    SELECT array_agg(jobid) INTO v_jobids
    FROM cron.job
    WHERE jobname IN ('telemetry_snapshot', 'telemetry_sample', 'telemetry_cleanup');

    -- Unschedule jobs
    PERFORM cron.unschedule('telemetry_snapshot')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'telemetry_snapshot');

    PERFORM cron.unschedule('telemetry_sample')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'telemetry_sample');

    PERFORM cron.unschedule('telemetry_cleanup')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'telemetry_cleanup');

    -- Clean up job run history
    IF v_jobids IS NOT NULL THEN
        DELETE FROM cron.job_run_details WHERE jobid = ANY(v_jobids);
        GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
        IF v_deleted_count > 0 THEN
            RAISE NOTICE 'Cleaned up % job run history records', v_deleted_count;
        END IF;
    END IF;
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
    RAISE NOTICE '  - All cron job execution history';
    RAISE NOTICE '';
END;
$$;
