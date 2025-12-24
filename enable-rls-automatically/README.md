# enable-rls-automatically

PostgreSQL event trigger that automatically enables Row Level Security (RLS) with FORCE option on all newly-created tables in the public schema.

## Why?

Supabase uses RLS as its primary access control mechanism. Forgetting to enable RLS on a table can expose data to unauthorized access. This event trigger ensures every new table in the public schema has RLS enabled by default.

The `FORCE` option ensures RLS policies apply even to table owners (like the `postgres` role), which is important in Supabase where service roles bypass RLS by default.

## Requirements

- Supabase project (local or hosted)
- Supabase CLI (`supabase --version` >= 1.0)
- Docker (for local development)

## Quick Start

### Local Development

```bash
# Start local Supabase
supabase start

# Apply migration (enables the trigger)
supabase db reset

# Run tests
supabase test db
```

### Deploy to Hosted Project

```bash
# Link to your project
supabase link --project-ref <your-project-ref>

# Push migration
supabase db push
```

## Usage

Once deployed, RLS is automatically enabled on any new table created in the public schema:

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

## Project Structure

```
enable-rls-automatically/
├── supabase/
│   ├── config.toml              # Supabase configuration
│   ├── migrations/
│   │   └── 20241224000000_enable_rls_trigger.sql
│   └── tests/
│       └── 00001_rls_trigger_test.sql
├── install.sql                  # Standalone install (non-Supabase)
├── uninstall.sql                # Standalone uninstall
└── README.md
```

## Testing

The test suite uses [pgTAP](https://pgtap.org/) via `supabase test db`.

### Run Tests Locally

```bash
# Ensure local Supabase is running
supabase start

# Run all tests (34 tests)
supabase test db
```

### Test Coverage

| Category | Tests | Description |
|----------|-------|-------------|
| Installation Verification | 4 | Function/trigger existence, correct event binding |
| Core Functionality | 4 | RLS + FORCE enabled on basic/constrained tables |
| Schema Filtering | 4 | public only; temp/private/auth ignored |
| CREATE TABLE Variants | 6 | CTAS, LIKE, IF NOT EXISTS, UNLOGGED, partitioned |
| Non-Triggering DDL | 5 | Views, matviews, ALTER, INDEX, SEQUENCE |
| Edge Cases | 5 | Special chars, mixed case, reserved words, idempotency |
| Transaction Behavior | 2 | Savepoint rollback, visibility |
| Uninstall Verification | 4 | Disable/enable trigger, behavior changes |

## Standalone Installation (Non-Supabase)

For PostgreSQL without Supabase:

```bash
# Install
psql -f install.sql

# Uninstall
psql -f uninstall.sql
```

Requires PostgreSQL 9.3+ and superuser or `rds_superuser` privileges.

## Important Notes

- This only affects **new** tables created after installation
- Existing tables are not modified; enable RLS on them manually if needed
- You still need to create RLS policies for the tables; this just enables the RLS mechanism
- Tables without policies will deny all access (except to superusers/owners without FORCE)
