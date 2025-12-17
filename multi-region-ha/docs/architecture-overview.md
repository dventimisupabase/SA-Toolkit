# Architecture Overview

## Introduction

This document describes a single-writer, multi-region disaster recovery (DR) architecture for Supabase. The design prioritizes data consistency over automatic failover, avoiding split-brain scenarios while providing predictable RTO/RPO.

## Architecture Diagram

```
                                    ┌─────────────────────────────────────────┐
                                    │         Active Region Flag              │
                                    │   (DNS / Feature Flag / Config Store)   │
                                    └─────────────────────────────────────────┘
                                                        │
                    ┌───────────────────────────────────┼───────────────────────────────────┐
                    │                                   │                                   │
                    ▼                                   ▼                                   ▼
        ┌───────────────────┐               ┌───────────────────┐               ┌───────────────────┐
        │   Applications    │               │   Edge Functions  │               │   Realtime        │
        │                   │               │   (Both Regions)  │               │   Clients         │
        └─────────┬─────────┘               └─────────┬─────────┘               └─────────┬─────────┘
                  │                                   │                                   │
                  │                                   │                                   │
                  ▼                                   ▼                                   │
        ┌─────────────────────────────────────────────────────────────────────┐           │
        │                      PgBouncer on Fly.io                            │           │
        │                   (Multi-Region Deployment)                         │           │
        │                                                                     │           │
        │   - Stable connection endpoint                                      │           │
        │   - PAUSE/RESUME for switchover                                     │           │
        │   - Upstream DSN swap during failover                               │           │
        └─────────────────────────────────────────────────────────────────────┘           │
                                        │                                                 │
                    ┌───────────────────┴───────────────────┐                             │
                    │                                       │                             │
                    ▼                                       ▼                             ▼
┌─────────────────────────────────────┐   ┌─────────────────────────────────────┐
│          Region A (Primary)         │   │         Region B (Standby)          │
│                                     │   │                                     │
│  ┌─────────────────────────────┐    │   │    ┌─────────────────────────────┐  │
│  │    Supabase Project A       │    │   │    │    Supabase Project B       │  │
│  │                             │    │   │    │                             │  │
│  │  ┌───────────────────────┐  │    │   │    │  ┌───────────────────────┐  │  │
│  │  │     PostgreSQL        │──┼────┼───┼────┼──│     PostgreSQL        │  │  │
│  │  │   (Primary Writer)    │  │    │   │    │  │  (Read-Only Standby)  │  │  │
│  │  └───────────────────────┘  │    │   │    │  └───────────────────────┘  │  │
│  │           │                 │    │   │    │                             │  │
│  │           │ Logical         │    │   │    │                             │  │
│  │           │ Replication     │    │   │    │                             │  │
│  │           │ (One-Way CDC)   │    │   │    │                             │  │
│  │           ▼                 │    │   │    │                             │  │
│  │  ┌───────────────────────┐  │    │   │    │  ┌───────────────────────┐  │  │
│  │  │   Supabase Storage    │  │    │   │    │  │   Supabase Storage    │  │  │
│  │  │   (Metadata Only)     │  │    │   │    │  │   (Metadata Only)     │  │  │
│  │  └───────────────────────┘  │    │   │    │  └───────────────────────┘  │  │
│  │                             │    │   │    │                             │  │
│  │  ┌───────────────────────┐  │    │   │    │  ┌───────────────────────┐  │  │
│  │  │      Realtime         │  │    │   │    │  │      Realtime         │  │  │
│  │  │   (Region-Local)      │  │    │   │    │  │   (Region-Local)      │  │  │
│  │  └───────────────────────┘  │    │   │    │  └───────────────────────┘  │  │
│  │                             │    │   │    │                             │  │
│  │  ┌───────────────────────┐  │    │   │    │  ┌───────────────────────┐  │  │
│  │  │    Edge Functions     │  │    │   │    │  │    Edge Functions     │  │  │
│  │  │   (Identical Code)    │  │    │   │    │  │   (Identical Code)    │  │  │
│  │  └───────────────────────┘  │    │   │    │  └───────────────────────┘  │  │
│  │                             │    │   │    │                             │  │
│  └─────────────────────────────┘    │   │    └─────────────────────────────┘  │
│                                     │   │                                     │
└─────────────────────────────────────┘   └─────────────────────────────────────┘

                                        │
                                        ▼
                    ┌─────────────────────────────────────────────────────────┐
                    │           External Multi-Region Object Storage          │
                    │            (S3 with CRR, Cloudflare R2, etc.)           │
                    │                                                         │
                    │              Canonical source for file data             │
                    └─────────────────────────────────────────────────────────┘
```

## Component Responsibilities

### PgBouncer on Fly.io

PgBouncer serves as the stable connection endpoint for all database connections:

- **Connection pooling**: Reduces connection overhead to Supabase
- **Endpoint stability**: Applications connect to a single, unchanging endpoint
- **Failover support**: PAUSE/RESUME commands enable zero-downtime upstream swap
- **Multi-region deployment**: Deployed to multiple Fly.io regions for low latency

### Supabase Project A (Primary)

The active write region:

- Accepts all write operations
- Source for logical replication
- Runs Edge Functions for active region
- Hosts Realtime subscriptions for connected clients

### Supabase Project B (Standby)

Warm standby that receives replicated data:

- Read-only by default (subscription active)
- Receives CDC via PostgreSQL logical replication
- Ready to be promoted during failover
- Edge Functions deployed but inactive

### PostgreSQL Logical Replication

One-way change data capture:

- Publication on primary, subscription on standby
- Asynchronous replication (non-zero RPO)
- **Never bidirectional** - prevents split-brain
- Explicit direction controlled by subscription state

### External Multi-Region Object Storage

Canonical storage for file data:

- Applications write files directly to external storage
- Supabase Storage stores metadata only
- Multi-region replication handled by storage provider (S3 CRR, R2, etc.)
- Decouples file availability from database failover

### Active-Region Flag

Global control plane for routing:

- Determines which region receives traffic
- Updated during failover procedure
- Can be implemented as:
  - DNS (Route53, Cloudflare)
  - Feature flag service (LaunchDarkly, etc.)
  - Configuration store (AWS Parameter Store, etc.)

## Design Constraints

| Constraint | Rationale |
|------------|-----------|
| Single writer at all times | Prevents split-brain and data conflicts |
| One-way CDC only | Simplifies consistency model |
| Manual failover | Allows human verification before promotion |
| No zero-RPO guarantee | Async replication has inherent lag |
| Auth sessions invalidate | Simplifies failover vs. session replication |
| Realtime state not replicated | Ephemeral nature makes replication impractical |

## Limitations

### No Physical Backup Access

Supabase uses WAL-G internally for physical backups, but customers cannot access these backups directly. This has implications for standby initialization:

| Requirement | Physical Backup Tools Need | Supabase Provides |
|-------------|---------------------------|-------------------|
| File system access | Direct access to `PGDATA` | Database access only |
| WAL archiving control | `archive_command` configuration | Managed internally |
| Server-side agent | Runs on PostgreSQL host | No SSH/shell access |

**Consequence**: The standby must be initialized using logical methods:

1. **Logical replication initial sync** (`copy_data=true`) - Used by this implementation
2. **`pg_dump`/`pg_restore`** with `copy_data=false` - Alternative for more control

For very large databases (hundreds of GB to TB scale), this means longer initial sync times compared to physical backup restoration. Plan accordingly when setting up DR for large datasets.

## Data Flow

### Normal Operation

1. Application connects to PgBouncer
2. PgBouncer routes to Primary (Project A)
3. Writes go to Primary PostgreSQL
4. Logical replication streams changes to Standby
5. Files written to external storage directly
6. Realtime events served from Primary

### During Failover

1. PgBouncer paused (connections queued)
2. Primary frozen (if reachable)
3. Sequences synchronized to Standby
4. Active-region flag flipped
5. Standby promoted (subscription dropped)
6. PgBouncer upstream swapped to new Primary
7. PgBouncer resumed (connections flow to new Primary)

## RTO/RPO Expectations

| Metric | Expected Value | Notes |
|--------|----------------|-------|
| RPO | Seconds to minutes | Depends on replication lag at failure time |
| RTO (scripted) | 2-5 minutes | With prepared scripts and runbooks |
| RTO (manual) | 5-15 minutes | With human verification at each step |

## Related Documents

- [Prerequisites](prerequisites.md)
- [Logical Replication Setup](logical-replication-setup.md)
- [PgBouncer on Fly.io Setup](pgbouncer-flyio-setup.md)
- [Failover Runbook](../runbooks/failover-runbook.md)
