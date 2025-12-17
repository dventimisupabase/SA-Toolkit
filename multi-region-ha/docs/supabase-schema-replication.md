# Supabase Schema Replication Strategy

Supabase projects include several system schemas beyond your application's `public` schema. This document explains how to handle each schema in your replication strategy.

## Schema Overview

| Schema               | Purpose          | Replicate?   | Notes                     |
|----------------------|------------------|--------------|---------------------------|
| `public`             | Application data | **Yes**      | All user tables           |
| `auth`               | Authentication   | **Partial**  | Users yes, sessions no    |
| `storage`            | File metadata    | **Optional** | If using Supabase Storage |
| `realtime`           | Realtime state   | **No**       | Ephemeral                 |
| `supabase_functions` | Edge Functions   | **No**       | Code, not data            |
| `extensions`         | Extension data   | **No**       | Generally not needed      |
| `graphql`            | GraphQL cache    | **No**       | Ephemeral                 |
| `vault`              | Secrets          | **No**       | Security concern          |
| `pgsodium`           | Encryption       | **No**       | Security concern          |

## Public Schema

### Recommendation: Replicate All Tables

Your application data lives here. Replicate everything.

```sql
-- Option 1: All tables in public (PostgreSQL 15+)
CREATE PUBLICATION dr_publication FOR TABLES IN SCHEMA public;

-- Option 2: Explicit list (any version)
CREATE PUBLICATION dr_publication FOR TABLE
    public.users,
    public.orders,
    public.products;
    -- Add all your tables
```

### Requirements

- All tables must have **primary keys**
- No `UNLOGGED` tables (they cannot be replicated)
- Sequences are NOT replicated (see [sequence-synchronization.md](sequence-synchronization.md))

## Auth Schema

### Tables in `auth` Schema

| Table                    | Replicate? | Rationale                               |
|--------------------------|------------|-----------------------------------------|
| `auth.users`             | **Yes**    | Core user data, emails, metadata        |
| `auth.identities`        | **Yes**    | OAuth identities                        |
| `auth.sessions`          | No         | Ephemeral, users re-auth after failover |
| `auth.refresh_tokens`    | No         | Ephemeral, regenerated on login         |
| `auth.mfa_factors`       | **Yes**    | MFA configuration                       |
| `auth.mfa_challenges`    | No         | Ephemeral                               |
| `auth.mfa_amr_claims`    | No         | Ephemeral                               |
| `auth.flow_state`        | No         | Ephemeral OAuth flow state              |
| `auth.saml_providers`    | **Yes**    | SAML configuration                      |
| `auth.saml_relay_states` | No         | Ephemeral                               |
| `auth.sso_providers`     | **Yes**    | SSO configuration                       |
| `auth.sso_domains`       | **Yes**    | SSO domain mapping                      |
| `auth.audit_log_entries` | Optional   | Audit trail                             |
| `auth.instances`         | No         | Instance metadata                       |
| `auth.schema_migrations` | No         | Migration history                       |

### Recommended Auth Replication

```sql
-- Add auth tables to publication
ALTER PUBLICATION dr_publication ADD TABLE
    auth.users,
    auth.identities,
    auth.mfa_factors,
    auth.saml_providers,
    auth.sso_providers,
    auth.sso_domains;
```

### User Impact After Failover

- Users will need to **re-authenticate** (sessions not replicated)
- Passwords and MFA are preserved
- OAuth connections preserved (but tokens need refresh)

### Application Handling

```javascript
// Example: Handle auth errors gracefully after failover
supabase.auth.onAuthStateChange((event, session) => {
  if (event === 'SIGNED_OUT' || event === 'TOKEN_REFRESHED') {
    // Session may have been invalidated by failover
    // Redirect to login if needed
  }
});
```

## Storage Schema

### Tables in `storage` Schema

| Table                | Replicate? | Rationale            |
|----------------------|------------|----------------------|
| `storage.buckets`    | **Yes**    | Bucket configuration |
| `storage.objects`    | **Yes**    | File metadata        |
| `storage.migrations` | No         | Migration history    |

### Important: Files vs Metadata

**Logical replication only copies database rows (metadata), NOT the actual files.**

Options for file data:

1. **External storage (recommended)**: Use S3/R2 as canonical source
2. **Manual sync**: Copy files between Supabase Storage buckets
3. **Accept data loss**: Rebuild file index after failover

### If Using Supabase Storage with Replication

```sql
-- Add storage metadata tables
ALTER PUBLICATION dr_publication ADD TABLE
    storage.buckets,
    storage.objects;
```

### External Storage Strategy (Recommended)

Instead of relying on Supabase Storage replication:

1. Application writes files to external multi-region storage (S3, R2)
2. Store only the external URL in your database
3. Supabase Storage used only for convenience features (if at all)

```sql
-- Example: Store external URLs
CREATE TABLE public.documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    external_url TEXT NOT NULL,  -- S3/R2 URL
    created_at TIMESTAMPTZ DEFAULT now()
);
```

## Realtime Schema

### Recommendation: Do NOT Replicate

The `realtime` schema contains ephemeral state for active subscriptions:

- Presence state
- Broadcast channels
- Subscription metadata

### After Failover

- All realtime connections drop
- Clients reconnect to new primary
- Presence state rebuilds naturally
- No data loss (realtime is ephemeral by design)

### Client Handling

```javascript
// Realtime will automatically reconnect
// Ensure your client handles reconnection
const channel = supabase.channel('room1')
  .on('presence', { event: 'sync' }, () => {
    // Handle presence sync after reconnection
  })
  .subscribe();
```

## Edge Functions (supabase_functions)

### Recommendation: Do NOT Replicate

Edge Functions are **code**, not data. They should be:

1. Deployed to **both** Supabase projects
2. Use identical versions
3. Connect to PgBouncer (not directly to Supabase)

### Deployment Strategy

```bash
# Deploy to both projects
supabase functions deploy my-function --project-ref $PRIMARY_REF
supabase functions deploy my-function --project-ref $STANDBY_REF
```

### Function Configuration

Edge Functions should use environment variables for database connection:

```typescript
// In Edge Function
const supabaseUrl = Deno.env.get('PGBOUNCER_URL');
// PgBouncer URL switches automatically during failover
```

## Vault and pgsodium

### Recommendation: Do NOT Replicate

These contain sensitive encryption keys and secrets.

### Manual Key Management

If you use Supabase Vault:

1. Document which secrets are stored
2. Recreate secrets on standby manually
3. Use external secret management (AWS Secrets Manager, etc.) as source of truth

## Publication Configuration Summary

### Minimal (Application Data Only)

```sql
CREATE PUBLICATION dr_publication FOR TABLES IN SCHEMA public;
```

### Recommended (With Auth)

```sql
CREATE PUBLICATION dr_publication FOR TABLES IN SCHEMA public;

ALTER PUBLICATION dr_publication ADD TABLE
    auth.users,
    auth.identities,
    auth.mfa_factors;
```

### Full (With Storage Metadata)

```sql
CREATE PUBLICATION dr_publication FOR TABLES IN SCHEMA public;

ALTER PUBLICATION dr_publication ADD TABLE
    auth.users,
    auth.identities,
    auth.mfa_factors,
    auth.saml_providers,
    auth.sso_providers,
    auth.sso_domains,
    storage.buckets,
    storage.objects;
```

## Schema Restrictions (Important)

As of April 2025, Supabase restricts certain DDL operations on system schemas:

> Destructive actions on `auth`, `storage`, and `realtime` schemas are limited.

**Impact on Replication:**
- Standard replication setup works
- Custom modifications to system tables may be restricted
- Test your publication setup before relying on it

Reference: [Supabase Schema Restrictions Discussion](https://github.com/orgs/supabase/discussions/34270)

## Verification Queries

### Check What's Being Replicated

```sql
-- On Primary: List tables in publication
SELECT
    schemaname,
    tablename
FROM pg_publication_tables
WHERE pubname = 'dr_publication'
ORDER BY schemaname, tablename;
```

### Check Row Counts Match

```sql
-- Run on both Primary and Standby, compare results
SELECT
    schemaname,
    relname,
    n_live_tup
FROM pg_stat_user_tables
WHERE schemaname IN ('public', 'auth', 'storage')
ORDER BY schemaname, relname;
```

## Related Documents

- [Logical Replication Setup](logical-replication-setup.md)
- [Storage Strategy](storage-strategy.md)
- [Sequence Synchronization](sequence-synchronization.md)
