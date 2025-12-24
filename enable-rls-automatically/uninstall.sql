-- Uninstall RLS auto-enable event trigger
--
-- Usage: psql -f uninstall.sql

DROP EVENT TRIGGER IF EXISTS enable_rls_trigger;
DROP FUNCTION IF EXISTS enable_rls_on_new_tables();
