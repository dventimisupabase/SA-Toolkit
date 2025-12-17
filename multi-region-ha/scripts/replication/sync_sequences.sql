-- ============================================================
-- Sync Sequences (Run on STANDBY before Failover)
-- ============================================================
-- PostgreSQL logical replication does NOT replicate sequences.
-- This script synchronizes sequence values from primary to standby
-- with a buffer to prevent conflicts after failover.
--
-- Usage:
--   1. Update the connection string below
--   2. Adjust buffer size if needed (default: 10000)
--   3. Run on STANDBY database
-- ============================================================

-- ============================================================
-- Configuration
-- ============================================================
\set buffer 10000
\set primary_host 'db.<PRIMARY_REF>.supabase.co'
\set primary_password '<PASSWORD>'

-- ============================================================
-- Method 1: Using dblink (Recommended)
-- ============================================================

-- Enable dblink extension if not already enabled
CREATE EXTENSION IF NOT EXISTS dblink;

-- Create the synchronization function
CREATE OR REPLACE FUNCTION sync_sequences_from_primary(
    p_primary_conninfo TEXT,
    p_buffer BIGINT DEFAULT 10000
)
RETURNS TABLE (
    sequence_name TEXT,
    primary_value BIGINT,
    new_value BIGINT,
    status TEXT
) AS $$
DECLARE
    seq RECORD;
    v_primary_val BIGINT;
    v_current_val BIGINT;
    v_new_val BIGINT;
BEGIN
    -- Connect to primary
    BEGIN
        PERFORM dblink_connect('primary_conn', p_primary_conninfo);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Failed to connect to primary: %', SQLERRM;
    END;

    -- Iterate through all user sequences
    FOR seq IN
        SELECT
            n.nspname AS schema_name,
            c.relname AS seq_name,
            n.nspname || '.' || c.relname AS full_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'S'  -- Sequences
        AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        ORDER BY n.nspname, c.relname
    LOOP
        BEGIN
            -- Get primary sequence value
            SELECT val INTO v_primary_val
            FROM dblink(
                'primary_conn',
                format('SELECT last_value FROM %I.%I', seq.schema_name, seq.seq_name)
            ) AS t(val BIGINT);

            -- Get current standby value
            EXECUTE format('SELECT last_value FROM %I.%I', seq.schema_name, seq.seq_name)
            INTO v_current_val;

            -- Calculate new value with buffer
            v_new_val := v_primary_val + p_buffer;

            -- Only update if new value is higher than current
            IF v_new_val > v_current_val THEN
                EXECUTE format('SELECT setval(%L, %s)', seq.full_name, v_new_val);

                sequence_name := seq.full_name;
                primary_value := v_primary_val;
                new_value := v_new_val;
                status := 'UPDATED';
                RETURN NEXT;
            ELSE
                sequence_name := seq.full_name;
                primary_value := v_primary_val;
                new_value := v_current_val;
                status := 'SKIPPED (already ahead)';
                RETURN NEXT;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            sequence_name := seq.full_name;
            primary_value := NULL;
            new_value := NULL;
            status := 'ERROR: ' || SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;

    -- Disconnect from primary
    PERFORM dblink_disconnect('primary_conn');

    RETURN;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Execute Synchronization
-- ============================================================

-- Replace connection string with actual values!
SELECT * FROM sync_sequences_from_primary(
    'host=db.<PRIMARY_REF>.supabase.co port=5432 user=postgres password=<PASSWORD> dbname=postgres',
    10000  -- buffer
);

-- ============================================================
-- Method 2: Manual (if dblink unavailable)
-- ============================================================
-- Run this query on PRIMARY to get current sequence values:
--
-- SELECT
--     format('SELECT setval(%L, %s);',
--            schemaname || '.' || sequencename,
--            last_value + 10000)
-- FROM pg_sequences
-- WHERE schemaname NOT IN ('pg_catalog', 'information_schema');
--
-- Then copy the output and run on STANDBY.

-- ============================================================
-- Verification
-- ============================================================

-- Check current sequence values on standby
SELECT
    schemaname || '.' || sequencename AS sequence_name,
    last_value,
    last_value - 10000 AS "estimated_primary_value (approx)"
FROM pg_sequences
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schemaname, sequencename;

-- ============================================================
-- Cleanup (Optional)
-- ============================================================
-- DROP FUNCTION IF EXISTS sync_sequences_from_primary(TEXT, BIGINT);
