# Prerequisites

Before implementing the multi-region HA architecture, ensure all prerequisites are met.

## Supabase Requirements

### Two Supabase Projects

- [ ] Project A (Primary) - created in Region 1 (e.g., US East)
- [ ] Project B (Standby) - created in Region 2 (e.g., US West)
- [ ] Both projects on **Pro plan or higher** (required for direct database connections)

### Database Access

- [ ] Direct connection strings for both projects (port 5432, not pooler port 6543)
- [ ] `postgres` user credentials for both projects
- [ ] Network connectivity between regions (Supabase allows logical replication)

### PostgreSQL Version

- [ ] PostgreSQL 15 or higher on both projects
- [ ] Verify: `SELECT version();`

### IPv4/IPv6 Connectivity

- [ ] IPv4 add-on enabled if your infrastructure doesn't support IPv6
- [ ] Verify connectivity to both `db.<project-ref>.supabase.co` endpoints

## Fly.io Requirements

### Account Setup

- [ ] Fly.io account created
- [ ] Credit card added (required for multi-region deployment)
- [ ] `flyctl` CLI installed

```bash
# Install flyctl
curl -L https://fly.io/install.sh | sh

# Login
flyctl auth login
```

### Regions

- [ ] Identify target Fly.io regions
  - Primary region (e.g., `iad` - Ashburn, US East)
  - Secondary region (e.g., `sjc` - San Jose, US West)

## Schema Requirements

### Application Tables

- [ ] All application tables in `public` schema
- [ ] Primary keys defined on all tables to be replicated
- [ ] No tables with `UNLOGGED` (cannot be replicated)

### Supabase System Schemas

Review which schemas will be replicated:

| Schema               | Include in Publication | Notes                                                              |
|----------------------|------------------------|--------------------------------------------------------------------|
| `public`             | Yes                    | Application data                                                   |
| `auth`               | Partial                | Users, identities, MFA ([details](supabase-schema-replication.md)) |
| `storage`            | Optional               | Metadata tables only                                               |
| `realtime`           | No                     | Ephemeral state                                                    |
| `supabase_functions` | No                     | Function definitions, not data                                     |
| `extensions`         | No                     | Extension state                                                    |

### Sequences

- [ ] Document all sequences used by application
- [ ] Plan for sequence synchronization (default: +10000 buffer)
- [ ] Consider UUIDs for new tables

## External Storage Requirements

### Object Storage

- [ ] Multi-region object storage account (choose one):
  - AWS S3 with Cross-Region Replication
  - Cloudflare R2 (automatic multi-region)
  - Google Cloud Storage with dual-region
  - Other S3-compatible storage with replication

- [ ] Bucket created and configured
- [ ] Access credentials (access key, secret key)
- [ ] CORS configured if accessed from browser

## Active-Region Flag

Choose and configure one of:

- [ ] **DNS-based**: Route53, Cloudflare DNS with health checks
- [ ] **Feature flag service**: LaunchDarkly, Unleash, etc.
- [ ] **Config store**: AWS Parameter Store, Consul, etcd

## Application Requirements

### Connection String Management

- [ ] Applications use environment variable for database URL
- [ ] Connection string points to PgBouncer, not directly to Supabase
- [ ] Connection retry logic implemented

### Auth Session Handling

- [ ] Application handles re-authentication after failover
- [ ] Session timeout configured appropriately
- [ ] User-facing messaging for service interruption

### Realtime Reconnection

- [ ] Realtime clients implement reconnection logic
- [ ] Exponential backoff for reconnection attempts
- [ ] State re-sync after reconnection

## Network Requirements

### Firewall/Security Groups

- [ ] PgBouncer can reach both Supabase projects on port 5432
- [ ] Applications can reach PgBouncer
- [ ] Monitoring can reach all components

### DNS TTL

- [ ] Low TTL on application-facing DNS records (60-300 seconds)
- [ ] Understand propagation time for DNS-based failover

## Operational Requirements

### Monitoring

- [ ] Alerting for replication lag threshold
- [ ] PgBouncer connection pool monitoring
- [ ] Supabase dashboard access for both projects

### Runbook Access

- [ ] On-call team has access to:
  - Supabase dashboards (both projects)
  - Fly.io dashboard and CLI
  - Active-region flag management
  - This documentation

### Testing

- [ ] Staging environment for DR testing
- [ ] Scheduled DR test cadence (quarterly recommended)

## Checklist Summary

```
Supabase:
[ ] Two projects in different regions (Pro plan+)
[ ] Direct connection strings (port 5432)
[ ] PostgreSQL 15+
[ ] IPv4/IPv6 connectivity verified

Fly.io:
[ ] Account with credit card
[ ] flyctl installed
[ ] Regions identified

Schema:
[ ] Tables have primary keys
[ ] Replication scope documented
[ ] Sequence strategy planned

External:
[ ] Multi-region object storage configured
[ ] Active-region flag mechanism chosen

Application:
[ ] PgBouncer connection string in env var
[ ] Re-auth handling implemented
[ ] Realtime reconnection logic

Operations:
[ ] Monitoring configured
[ ] Team has required access
[ ] DR test scheduled
```

## Next Steps

Once prerequisites are met:

1. [Set up PgBouncer on Fly.io](pgbouncer-flyio-setup.md)
2. [Configure logical replication](logical-replication-setup.md)
3. [Review failover runbook](../runbooks/failover-runbook.md)
