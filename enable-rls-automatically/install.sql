-- Enable RLS automatically on new tables in public schema
--
-- This event trigger automatically enables Row Level Security (RLS) with FORCE
-- option on all newly-created tables in the public schema.
--
-- Usage: psql -f install.sql

-- Function that enables RLS on newly created tables
CREATE OR REPLACE FUNCTION enable_rls_on_new_tables()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
        WHERE command_tag = 'CREATE TABLE'
          AND object_type = 'table'
    LOOP
        -- Only apply to public schema
        IF obj.schema_name = 'public' THEN
            EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', obj.object_identity);
            EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', obj.object_identity);
            RAISE NOTICE 'RLS enabled with FORCE on table: %', obj.object_identity;
        END IF;
    END LOOP;
END;
$$;

-- Event trigger that fires after CREATE TABLE
CREATE EVENT TRIGGER enable_rls_trigger
ON ddl_command_end
WHEN TAG IN ('CREATE TABLE')
EXECUTE FUNCTION enable_rls_on_new_tables();
