# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Solutions Architect Toolkit - a collection of tools, scripts, and programs useful for Solutions Architects supporting PostgreSQL database products (primarily Supabase).

Each tool has its own README with detailed documentation. See individual READMEs for full usage instructions.

## Design Principles

- **Standard libpq authentication**: Use `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD` environment variables or `.pgpass`
- **Auto-detection over manual config**: Prefer querying the database for configuration (e.g., PG version) rather than requiring user input
- **Supabase-first, PostgreSQL-compatible**: Optimized for Supabase but works with standard PostgreSQL where possible

## Tools

### pg-telemetry/

Server-side performance telemetry for PostgreSQL 15, 16, or 17. Continuously collects metrics and provides analysis functions to diagnose any time window.

**See:** [pg-telemetry/README.md](pg-telemetry/README.md)

**Quick Reference:**
```bash
psql -f pg-telemetry/sql/install.sql    # Install
psql -f pg-telemetry/sql/uninstall.sql  # Uninstall
```

```sql
-- Recent activity views
SELECT * FROM telemetry.recent_waits;
SELECT * FROM telemetry.recent_locks;
SELECT * FROM telemetry.recent_activity;

-- Time window analysis
SELECT * FROM telemetry.compare('2024-12-16 14:00', '2024-12-16 15:00');
SELECT * FROM telemetry.wait_summary('2024-12-16 14:00', '2024-12-16 15:00');
```

**Requirements:** PostgreSQL 15+, pg_cron extension (1.4.1+ recommended)

### multi-region-ha/

Reference architecture for single-writer, multi-region disaster recovery for Supabase.

**See:** [multi-region-ha/README.md](multi-region-ha/README.md)

**Quick Reference:**
```bash
./multi-region-ha/scripts/health/check_primary_health.sh
./multi-region-ha/scripts/health/check_replication_lag.sh
./multi-region-ha/scripts/failover/failover.sh
./multi-region-ha/scripts/failover/failover.sh --skip-freeze  # Emergency
```

**Requirements:** Two Supabase projects (Pro+), Fly.io account, PostgreSQL 15+

### storage-to-s3/

One-time migration tool to move objects from Supabase Storage to AWS S3.

**See:** [storage-to-s3/README.md](storage-to-s3/README.md)

**Quick Reference:**
```bash
./storage-to-s3/scripts/migrate.sh --dry-run  # Preview
./storage-to-s3/scripts/migrate.sh            # Migrate
./storage-to-s3/scripts/verify.sh             # Verify
```

**Requirements:** Supabase CLI (linked to project), AWS CLI v2

### enable-rls-automatically/

Event trigger that automatically enables RLS with FORCE on new tables in public schema.

**See:** [enable-rls-automatically/README.md](enable-rls-automatically/README.md)

**Quick Reference:**
```bash
supabase db push                                # Deploy to Supabase
psql -f enable-rls-automatically/install.sql   # Standalone PostgreSQL
psql -f enable-rls-automatically/uninstall.sql # Uninstall
supabase test db                               # Run pgTAP tests
```

**Requirements:** PostgreSQL 9.3+, superuser or rds_superuser privileges
