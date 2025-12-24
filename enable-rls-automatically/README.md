# enable-rls-automatically

PostgreSQL event trigger that automatically enables Row Level Security (RLS) with FORCE option on all newly-created tables in the public schema.

## Why?

Supabase uses RLS as its primary access control mechanism. Forgetting to enable RLS on a table can expose data to unauthorized access. This event trigger ensures every new table in the public schema has RLS enabled by default.

The `FORCE` option ensures RLS policies apply even to table owners (like the `postgres` role), which is important in Supabase where service roles bypass RLS by default.

## Requirements

- PostgreSQL 9.3+ (event triggers)
- Superuser or `rds_superuser` privileges (required to create event triggers)

## Installation

```bash
psql -f install.sql
```

## Uninstall

```bash
psql -f uninstall.sql
```

## Usage

Once installed, RLS is automatically enabled on any new table created in the public schema:

```sql
CREATE TABLE public.users (id int, email text);
-- NOTICE: RLS enabled with FORCE on table: public.users
```

Tables in other schemas are not affected:

```sql
CREATE TABLE private.internal_data (id int);
-- No RLS applied
```

## Verify

Check that RLS is enabled on a table:

```sql
SELECT relname, relrowsecurity, relforcerowsecurity
FROM pg_class
WHERE relname = 'your_table_name';
```

Both `relrowsecurity` and `relforcerowsecurity` should be `t` (true).

## How It Works

1. An event trigger fires on `ddl_command_end` after any `CREATE TABLE` statement
2. The trigger function checks if the new table is in the `public` schema
3. If so, it executes:
   - `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`
   - `ALTER TABLE ... FORCE ROW LEVEL SECURITY`

## Important Notes

- This only affects **new** tables created after installation
- Existing tables are not modified; enable RLS on them manually if needed
- You still need to create RLS policies for the tables; this just enables the RLS mechanism
- Tables without policies will deny all access (except to superusers/owners without FORCE)
