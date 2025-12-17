-- ============================================================
-- Setup Publication (Run on PRIMARY Supabase Project)
-- ============================================================
-- This script creates the publication and replication slot
-- for disaster recovery replication to a standby project.
--
-- Prerequisites:
--   - PostgreSQL 15+
--   - All tables have primary keys
--   - Run migrations on both primary and standby first
-- ============================================================

-- Configuration: Customize the tables to include
-- Option 1: All tables in public schema (PostgreSQL 15+)
-- Option 2: Explicit table list (uncomment and customize)
-- Option 3: Include auth/storage tables (uncomment as needed)

BEGIN;

-- ============================================================
-- Option 1: All Public Tables (Simplest)
-- ============================================================
CREATE PUBLICATION dr_publication FOR TABLES IN SCHEMA public;

-- ============================================================
-- Option 2: Explicit Table List
-- Uncomment and customize if you need specific tables only
-- ============================================================
-- CREATE PUBLICATION dr_publication FOR TABLE
--     public.users,
--     public.orders,
--     public.products,
--     public.order_items;

-- ============================================================
-- Add Auth Tables (Recommended)
-- User data is replicated; sessions are not (re-auth on failover)
-- ============================================================
ALTER PUBLICATION dr_publication ADD TABLE auth.users;
ALTER PUBLICATION dr_publication ADD TABLE auth.identities;

-- Uncomment if using MFA
-- ALTER PUBLICATION dr_publication ADD TABLE auth.mfa_factors;

-- Uncomment if using SAML/SSO
-- ALTER PUBLICATION dr_publication ADD TABLE auth.saml_providers;
-- ALTER PUBLICATION dr_publication ADD TABLE auth.sso_providers;
-- ALTER PUBLICATION dr_publication ADD TABLE auth.sso_domains;

-- ============================================================
-- Add Storage Tables (Optional)
-- Only metadata is replicated, not actual files
-- ============================================================
-- ALTER PUBLICATION dr_publication ADD TABLE storage.buckets;
-- ALTER PUBLICATION dr_publication ADD TABLE storage.objects;

COMMIT;

-- ============================================================
-- Create Replication Slot
-- ============================================================
-- The slot tracks what's been sent to the subscriber
-- Using pgoutput plugin (standard for logical replication)

SELECT pg_create_logical_replication_slot('dr_slot', 'pgoutput');

-- ============================================================
-- Verification
-- ============================================================

-- List tables in publication
SELECT schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'dr_publication'
ORDER BY schemaname, tablename;

-- Verify replication slot
SELECT slot_name, plugin, slot_type, active
FROM pg_replication_slots
WHERE slot_name = 'dr_slot';

-- ============================================================
-- Output connection info for subscription setup
-- ============================================================
SELECT
    'Connection string for standby subscription:' AS info,
    format(
        'host=%s port=5432 user=postgres password=<PASSWORD> dbname=postgres',
        current_setting('server_name', true)
    ) AS connection_template;
