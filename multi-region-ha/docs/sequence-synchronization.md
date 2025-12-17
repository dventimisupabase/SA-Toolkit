# Sequence Synchronization

PostgreSQL sequences are **not replicated** by logical replication. This document explains how to synchronize sequences before failover to prevent primary key conflicts.

## The Problem

When you failover to the standby:

1. Standby becomes writable
2. New inserts use standby's sequence values
3. If standby sequences are behind, you get **duplicate key errors**

Example:
- Primary sequence at: 10,000
- Standby sequence at: 5,000 (from initial sync)
- After failover, standby generates ID 5,001
- Conflict with existing replicated row!

## Solution: Pre-Failover Sequence Sync

Before promoting the standby, synchronize sequences with a buffer.

### The Buffer Strategy

Add a buffer (e.g., +10,000) to account for:
- In-flight transactions during failover
- Replication lag
- Safety margin

## Synchronization Script

### sync_sequences.sql

Run this on the **Standby** before failover:

```sql
-- Sequence Synchronization Script
-- Run on STANDBY before failover

-- This script:
-- 1. Queries sequence values from PRIMARY via dblink
-- 2. Sets STANDBY sequences to PRIMARY value + buffer

-- Configuration
\set buffer 10000

-- Create temporary function to sync sequences
CREATE OR REPLACE FUNCTION sync_sequences_from_primary(
    primary_conninfo TEXT,
    buffer_value BIGINT DEFAULT 10000
)
RETURNS TABLE (
    sequence_name TEXT,
    old_value BIGINT,
    new_value BIGINT
) AS $$
DECLARE
    seq RECORD;
    primary_val BIGINT;
    current_val BIGINT;
    new_val BIGINT;
BEGIN
    -- Enable dblink if not already
    CREATE EXTENSION IF NOT EXISTS dblink;

    -- Connect to primary
    PERFORM dblink_connect('primary_conn', primary_conninfo);

    FOR seq IN
        SELECT
            n.nspname AS schema_name,
            c.relname AS seq_name,
            n.nspname || '.' || c.relname AS full_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'S'
        AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    LOOP
        -- Get primary value
        SELECT val INTO primary_val
        FROM dblink(
            'primary_conn',
            format('SELECT last_value FROM %I.%I', seq.schema_name, seq.seq_name)
        ) AS t(val BIGINT);

        -- Get current standby value
        EXECUTE format('SELECT last_value FROM %I.%I', seq.schema_name, seq.seq_name)
        INTO current_val;

        -- Calculate new value
        new_val := primary_val + buffer_value;

        -- Only update if new value is higher
        IF new_val > current_val THEN
            EXECUTE format('SELECT setval(%L, %s)', seq.full_name, new_val);

            sequence_name := seq.full_name;
            old_value := current_val;
            new_value := new_val;
            RETURN NEXT;
        END IF;
    END LOOP;

    -- Disconnect
    PERFORM dblink_disconnect('primary_conn');

    RETURN;
END;
$$ LANGUAGE plpgsql;
```

### Usage

```sql
-- Run on Standby
SELECT * FROM sync_sequences_from_primary(
    'host=db.<PRIMARY_REF>.supabase.co port=5432 user=postgres password=<PASSWORD> dbname=postgres',
    10000  -- buffer
);
```

## Manual Synchronization

If dblink is not available, sync manually:

### Step 1: Get Sequences from Primary

```sql
-- Run on PRIMARY
SELECT
    schemaname || '.' || sequencename AS sequence_name,
    last_value
FROM pg_sequences
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schemaname, sequencename;
```

### Step 2: Generate setval Statements

```sql
-- Run on PRIMARY to generate SQL for standby
SELECT format(
    'SELECT setval(%L, %s);',
    schemaname || '.' || sequencename,
    last_value + 10000
)
FROM pg_sequences
WHERE schemaname NOT IN ('pg_catalog', 'information_schema');
```

### Step 3: Execute on Standby

Copy the generated statements and run on Standby:

```sql
-- Run on STANDBY (generated from Step 2)
SELECT setval('public.users_id_seq', 10234);
SELECT setval('public.orders_id_seq', 52891);
-- ... etc
```

## Shell Script Wrapper

### sync_sequences_for_failover.sh

```bash
#!/bin/bash
set -e

# Load configuration
source "$(dirname "$0")/../../config/.env"

BUFFER=${SEQUENCE_BUFFER:-10000}

echo "=== Sequence Synchronization ==="
echo "Primary: ${PRIMARY_HOST}"
echo "Standby: ${STANDBY_HOST}"
echo "Buffer: ${BUFFER}"
echo ""

# Get sequences from primary
echo "Fetching sequence values from primary..."
PRIMARY_SEQUENCES=$(psql "postgresql://postgres:${POSTGRES_PASSWORD}@${PRIMARY_HOST}:5432/postgres" -t -A -F'|' -c "
SELECT
    schemaname || '.' || sequencename,
    last_value
FROM pg_sequences
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
")

# Generate and execute setval on standby
echo "Synchronizing sequences to standby..."
while IFS='|' read -r seq_name last_value; do
    if [ -n "$seq_name" ]; then
        new_value=$((last_value + BUFFER))
        echo "  ${seq_name}: ${last_value} -> ${new_value}"
        psql "postgresql://postgres:${POSTGRES_PASSWORD}@${STANDBY_HOST}:5432/postgres" -c \
            "SELECT setval('${seq_name}', ${new_value});" > /dev/null
    fi
done <<< "$PRIMARY_SEQUENCES"

echo ""
echo "=== Sequence Synchronization Complete ==="
```

## Verification

After synchronization, verify sequences are ahead:

```sql
-- Run on STANDBY
SELECT
    schemaname || '.' || sequencename AS sequence_name,
    last_value,
    last_value - 10000 AS "estimated_primary_value"
FROM pg_sequences
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schemaname, sequencename;
```

## Alternative: Use UUIDs

For new tables, consider using UUIDs instead of sequences:

```sql
CREATE TABLE public.new_feature (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);
```

Benefits:
- No sequence synchronization needed
- Globally unique across regions
- Safe for future active-active (if ever needed)

Drawbacks:
- Larger storage (16 bytes vs 4-8 bytes)
- Less human-readable
- Slightly slower index operations

## Choosing Buffer Size

| Scenario               | Recommended Buffer | Rationale                 |
|------------------------|--------------------|---------------------------|
| Low write volume       | 10,000             | Safe default              |
| Medium write volume    | 100,000            | More headroom             |
| High write volume      | 1,000,000          | Accommodate rapid inserts |
| Time-critical failover | 10,000,000         | Maximum safety            |

Calculate based on:
- Peak inserts per second
- Maximum acceptable failover time
- Replication lag

Formula: `buffer = peak_inserts_per_second * max_failover_seconds * safety_factor`

## Failover Checklist

Before promoting standby:

- [ ] Run sequence synchronization script
- [ ] Verify all sequences are ahead of primary
- [ ] Document the buffer used
- [ ] Proceed with failover

## Related Documents

- [Logical Replication Setup](logical-replication-setup.md)
- [Failover Runbook](../runbooks/failover-runbook.md)
- [sync_sequences.sql](../scripts/replication/sync_sequences.sql)
