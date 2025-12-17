# Multi-Region Supabase HA/DR

A reference architecture for single-writer, multi-region disaster recovery for Supabase.

## Overview

This toolkit provides documentation, runbooks, and scripts for implementing a controlled failover architecture for Supabase projects. The design prioritizes **data consistency** over automatic failover, avoiding split-brain scenarios.

### Key Features

- **Single-writer architecture**: One primary, one warm standby
- **PgBouncer on Fly.io**: Stable connection endpoint with PAUSE/RESUME for zero-downtime switchover
- **PostgreSQL logical replication**: Native CDC, one-way only
- **External object storage**: Multi-region file storage decoupled from database
- **Controlled failover**: Human-verified, scripted procedure

### What This Is NOT

- Active-active multi-region writes
- Zero-RPO solution
- Fully automatic failover

## Quick Start

**New projects:**
1. [Review prerequisites](docs/prerequisites.md)
2. [Understand the architecture](docs/architecture-overview.md)
3. [Set up PgBouncer](docs/pgbouncer-flyio-setup.md)
4. [Configure replication](docs/logical-replication-setup.md)
5. [Practice failover](runbooks/testing-runbook.md)

**Existing Supabase projects:** Start with the [Migration Guide](docs/migration-guide-existing-projects.md) for step-by-step instructions on adding HA to your existing database with minimal disruption.

**Interactive visualization:** Open [visualization/index.html](visualization/index.html) in a browser to explore the architecture and failover process interactively.

## Directory Structure

```
multi-region-ha/
├── README.md                 # This file
├── docs/                     # Architecture and setup documentation
│   ├── architecture-overview.md
│   ├── prerequisites.md
│   ├── pgbouncer-flyio-setup.md
│   ├── logical-replication-setup.md
│   ├── supabase-schema-replication.md
│   ├── storage-strategy.md
│   ├── sequence-synchronization.md
│   └── migration-guide-existing-projects.md
├── visualization/            # Interactive architecture visualization
│   └── index.html
├── runbooks/                 # Operational procedures
│   ├── failover-runbook.md
│   ├── failback-runbook.md
│   ├── emergency-runbook.md
│   └── testing-runbook.md
├── scripts/                  # Automation scripts
│   ├── health/               # Health check scripts
│   ├── replication/          # Replication SQL and shell scripts
│   ├── failover/             # Failover orchestration
│   └── pgbouncer/            # PgBouncer management
├── flyio/                    # Fly.io deployment files
│   ├── fly.toml
│   ├── Dockerfile
│   └── *.template
└── config/                   # Example configurations
    └── env.example
```

## Architecture Summary

```
┌─────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│ Application │────▶│ PgBouncer (Fly.io)  │────▶│ Supabase Project A  │
└─────────────┘     └─────────────────────┘     │     (Primary)       │
                              │                 └──────────┬──────────┘
                              │                            │
                              │                    Logical Replication
                              │                            │
                              │                            ▼
                              │                 ┌─────────────────────┐
                              └ ─ ─ failover ─ ▶│ Supabase Project B  │
                                                │     (Standby)       │
                                                └─────────────────────┘
```

## Failover Procedure (Summary)

1. **Pause** PgBouncer (connections queue)
2. **Freeze** old primary (prevent writes)
3. **Sync** sequences to standby
4. **Flip** active-region flag
5. **Promote** standby (drop subscription)
6. **Swap** PgBouncer upstream DSN
7. **Resume** PgBouncer (traffic flows to new primary)

Full procedure: [runbooks/failover-runbook.md](runbooks/failover-runbook.md)

## RTO/RPO

| Metric | Target |
|--------|--------|
| RPO | Seconds to minutes (replication lag dependent) |
| RTO | 2-5 minutes (scripted) / 5-15 minutes (manual) |

## Requirements

- Two Supabase projects (Pro plan or higher)
- Fly.io account
- PostgreSQL 15+
- Multi-region object storage (S3, R2, etc.)

See [docs/prerequisites.md](docs/prerequisites.md) for full checklist.

## Configuration

Copy the example environment file and configure:

```bash
cp config/env.example config/.env
# Edit config/.env with your values
```

Required variables:
- `PRIMARY_HOST` - Primary Supabase direct connection host
- `STANDBY_HOST` - Standby Supabase direct connection host
- `POSTGRES_PASSWORD` - Database password
- `FLY_APP_NAME` - Your Fly.io app name

## Scripts

### Health Checks

```bash
# Check primary database health
./scripts/health/check_primary_health.sh

# Check replication lag
./scripts/health/check_replication_lag.sh

# Check PgBouncer status
./scripts/health/check_pgbouncer_health.sh
```

### Failover

```bash
# Full failover (with primary freeze)
./scripts/failover/failover.sh

# Emergency failover (skip freeze if primary unreachable)
./scripts/failover/failover.sh --skip-freeze
```

## Related Documents

- [PRD](multi_region_supabase_ha_prd.org) - Original requirements document
- [Supabase Replication Docs](https://supabase.com/docs/guides/database/replication)
- [Fly.io Documentation](https://fly.io/docs/)

## Support

This is a reference architecture provided as part of the SA-Toolkit. Adapt it to your specific requirements and test thoroughly before production use.
