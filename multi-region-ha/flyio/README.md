# PgBouncer on Fly.io

This directory contains the deployment files for running PgBouncer on Fly.io as the stable connection endpoint for the multi-region Supabase HA architecture.

## Overview

PgBouncer provides:
- **Stable endpoint**: Applications connect to one address regardless of which Supabase project is primary
- **Connection pooling**: Reduces connection overhead
- **Failover support**: PAUSE/RESUME commands enable zero-downtime upstream swap

## Prerequisites

- Fly.io account with credit card added
- `flyctl` CLI installed and authenticated
- Supabase project connection details

```bash
# Install flyctl
curl -L https://fly.io/install.sh | sh

# Authenticate
flyctl auth login
```

## Deployment

### 1. Create the Fly.io App

```bash
cd flyio/

# Create app (choose a unique name)
fly launch --name your-pgbouncer-app --region iad --no-deploy

# Create volume for runtime data
fly volumes create pgbouncer_data --region iad --size 1
```

### 2. Configure Secrets

```bash
# Primary Supabase connection (initial setup)
fly secrets set \
    DATABASE_HOST=db.your-primary-ref.supabase.co \
    DATABASE_NAME=postgres \
    DATABASE_USER=postgres \
    DATABASE_PASSWORD=your-postgres-password \
    PGBOUNCER_ADMIN_PASSWORD=your-admin-password
```

### 3. Deploy

```bash
fly deploy
```

### 4. Verify Deployment

```bash
# Check app status
fly status

# View logs
fly logs

# Test connection
psql "postgresql://postgres:password@your-pgbouncer-app.fly.dev:5432/postgres" -c "SELECT 1"
```

## Multi-Region Deployment

For lower latency, deploy to multiple regions:

```bash
# Add a second region
fly scale count 2 --region iad,sjc

# Or specific machines per region
fly machine clone --region sjc
```

## PgBouncer Administration

### Connecting to Admin Console

```bash
# Via fly ssh
fly ssh console

# Then connect to admin
psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer
```

### Common Admin Commands

```sql
-- Show pool status
SHOW POOLS;

-- Show active clients
SHOW CLIENTS;

-- Show server connections
SHOW SERVERS;

-- Pause all connections (for failover)
PAUSE;

-- Resume connections
RESUME;

-- Reload configuration
RELOAD;

-- Show stats
SHOW STATS;
```

## Failover Operations

### Pausing for Failover

```bash
# Pause connections (they queue, don't disconnect)
fly ssh console -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'PAUSE;'"
```

### Swapping Upstream

```bash
# Update to new primary
fly secrets set DATABASE_HOST=db.your-standby-ref.supabase.co

# Reload configuration (automatic after secrets change, but can force)
fly ssh console -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RELOAD;'"
```

### Resuming Connections

```bash
# Resume - connections flow to new primary
fly ssh console -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RESUME;'"
```

## Configuration

### Environment Variables

| Variable                      | Description                               | Default     |
|-------------------------------|-------------------------------------------|-------------|
| `DATABASE_HOST`               | Supabase host (db.xxx.supabase.co)        | Required    |
| `DATABASE_NAME`               | Database name                             | Required    |
| `DATABASE_USER`               | Database user                             | Required    |
| `DATABASE_PASSWORD`           | Database password                         | Required    |
| `PGBOUNCER_ADMIN_PASSWORD`    | Admin console password                    | Required    |
| `PGBOUNCER_POOL_MODE`         | Pool mode (transaction/session/statement) | transaction |
| `PGBOUNCER_MAX_CLIENT_CONN`   | Max client connections                    | 1000        |
| `PGBOUNCER_DEFAULT_POOL_SIZE` | Default pool size per database            | 20          |

### Pool Modes

- **transaction** (recommended for Supabase): Connection returned to pool after each transaction
- **session**: Connection held for entire client session
- **statement**: Connection returned after each statement (limited compatibility)

### Tuning

```bash
# Increase pool size for high-traffic apps
fly secrets set PGBOUNCER_DEFAULT_POOL_SIZE=50

# Increase max connections
fly secrets set PGBOUNCER_MAX_CLIENT_CONN=2000
```

## Monitoring

### Health Checks

Fly.io automatically performs TCP health checks on port 5432.

### Metrics

```sql
-- Connection statistics
SHOW STATS;

-- Pool utilization
SHOW POOLS;

-- Memory usage
SHOW MEM;
```

### Logs

```bash
# Stream logs
fly logs -f

# Recent logs
fly logs --limit 100
```

## Troubleshooting

### Connection Refused

1. Check app is running: `fly status`
2. Verify secrets are set: `fly secrets list`
3. Check logs: `fly logs`

### Pool Exhausted

```sql
-- Check pool status
SHOW POOLS;

-- If cl_waiting is high, increase pool size
```

```bash
fly secrets set PGBOUNCER_DEFAULT_POOL_SIZE=50
```

### High Latency

1. Ensure app is deployed in region closest to users
2. Consider multi-region deployment
3. Check Supabase database performance

### Admin Connection Fails

```bash
# Verify admin password is set
fly secrets list | grep PGBOUNCER_ADMIN

# Reset if needed
fly secrets set PGBOUNCER_ADMIN_PASSWORD=new-password
```

## Security Considerations

1. **Secrets**: All passwords stored as Fly.io secrets (encrypted)
2. **Admin port**: Not exposed externally, accessible only via `fly ssh`
3. **TLS**: Consider enabling client TLS for production (see pgbouncer.ini.template)

## Files

| File                     | Purpose                                |
|--------------------------|----------------------------------------|
| `fly.toml`               | Fly.io app configuration               |
| `Dockerfile`             | Container image definition             |
| `pgbouncer.ini.template` | PgBouncer configuration template       |
| `userlist.txt.template`  | PgBouncer authentication file template |
| `entrypoint.sh`          | Container startup script               |

## Related Documentation

- [Architecture Overview](../docs/architecture-overview.md)
- [Failover Runbook](../runbooks/failover-runbook.md)
- [PgBouncer Docs](https://www.pgbouncer.org/config.html)
- [Fly.io Docs](https://fly.io/docs/)
