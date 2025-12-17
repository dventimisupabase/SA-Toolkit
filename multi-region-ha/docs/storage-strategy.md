# Storage Strategy

This document outlines the approach for handling file storage in a multi-region Supabase deployment.

## The Challenge

Supabase Storage stores files in the project's region. Logical replication only copies **database rows** (file metadata), not the actual files.

Options:
1. **External multi-region storage** (recommended)
2. **Dual-write to both regions**
3. **Accept file unavailability after failover**

## Recommended: External Multi-Region Storage

Use a dedicated object storage service as the canonical source for files.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Application                              │
│                                                                  │
│   ┌────────────────────────────────────────────────────────┐    │
│   │  File Upload Flow:                                      │    │
│   │  1. Upload file to External Storage (S3/R2)            │    │
│   │  2. Get URL/key                                         │    │
│   │  3. Store URL in Supabase database                      │    │
│   └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                ┌───────────────────────────────┐
                │   External Object Storage     │
                │   (S3 with CRR, R2, GCS)      │
                │                               │
                │   - Multi-region replication  │
                │   - Single global namespace   │
                │   - Independent of Supabase   │
                └───────────────────────────────┘
                                │
                ┌───────────────┴───────────────┐
                │                               │
                ▼                               ▼
        ┌───────────────┐               ┌───────────────┐
        │   Region A    │               │   Region B    │
        │   (Primary)   │               │   (Standby)   │
        └───────────────┘               └───────────────┘
```

### Storage Provider Options

#### AWS S3 with Cross-Region Replication (CRR)

**Pros:**
- Battle-tested
- Fine-grained replication controls
- Integrates with CloudFront

**Setup:**
```bash
# Create buckets in two regions
aws s3 mb s3://myapp-files-us-east-1 --region us-east-1
aws s3 mb s3://myapp-files-us-west-2 --region us-west-2

# Enable versioning (required for CRR)
aws s3api put-bucket-versioning \
    --bucket myapp-files-us-east-1 \
    --versioning-configuration Status=Enabled

# Configure replication (see AWS docs for full policy)
```

**Cost considerations:**
- Replication transfer costs
- Storage in both regions

#### Cloudflare R2

**Pros:**
- Zero egress fees
- Automatic multi-region (no configuration needed)
- S3-compatible API

**Setup:**
```bash
# Create bucket via Cloudflare dashboard or API
# R2 is automatically multi-region
```

#### Google Cloud Storage (Dual-Region)

**Pros:**
- Built-in dual-region buckets
- Synchronous replication

**Setup:**
```bash
gsutil mb -l nam4 gs://myapp-files/  # nam4 = US dual-region
```

### Database Schema

Store external URLs instead of using Supabase Storage:

```sql
-- Document storage with external URLs
CREATE TABLE public.documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id),
    name TEXT NOT NULL,
    mime_type TEXT,
    size_bytes BIGINT,
    storage_key TEXT NOT NULL,      -- Key in external storage
    storage_url TEXT NOT NULL,       -- Full URL (or generate from key)
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Index for user lookups
CREATE INDEX idx_documents_user_id ON public.documents(user_id);
```

### Application Code

#### Upload Flow

```typescript
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

const s3 = new S3Client({ region: 'us-east-1' });

async function uploadFile(file: File, userId: string) {
    const key = `users/${userId}/${crypto.randomUUID()}/${file.name}`;

    // 1. Upload to S3
    await s3.send(new PutObjectCommand({
        Bucket: process.env.S3_BUCKET,
        Key: key,
        Body: file,
        ContentType: file.type,
    }));

    // 2. Store reference in Supabase
    const { data, error } = await supabase
        .from('documents')
        .insert({
            user_id: userId,
            name: file.name,
            mime_type: file.type,
            size_bytes: file.size,
            storage_key: key,
            storage_url: `https://${process.env.S3_BUCKET}.s3.amazonaws.com/${key}`,
        });

    return data;
}
```

#### Download Flow

```typescript
async function getFileUrl(documentId: string) {
    const { data } = await supabase
        .from('documents')
        .select('storage_url')
        .eq('id', documentId)
        .single();

    return data?.storage_url;

    // Or generate presigned URL for private files
    // return await getSignedUrl(s3, new GetObjectCommand({...}), { expiresIn: 3600 });
}
```

## Alternative: Supabase Storage with Mirroring

If you prefer using Supabase Storage, implement application-level mirroring.

### Dual-Write Pattern

```typescript
async function uploadToSupabase(file: File, path: string) {
    // Upload to primary
    const { data: primaryData, error: primaryError } = await supabasePrimary
        .storage
        .from('files')
        .upload(path, file);

    if (primaryError) throw primaryError;

    // Best-effort mirror to standby (async, don't block)
    supabaseStandby
        .storage
        .from('files')
        .upload(path, file)
        .catch(err => console.error('Mirror failed:', err));

    return primaryData;
}
```

### Drawbacks

- Increased upload latency (if synchronous)
- Potential inconsistency (if async)
- Double storage costs
- Complex error handling

## Option 3: Accept File Unavailability

For non-critical files, you might accept that files are unavailable immediately after failover.

### Recovery Process

1. Failover completes (database available)
2. File URLs return 404 (files in old region)
3. Run file migration job to copy files
4. Files become available

### When This Works

- Files are supplementary, not critical
- Acceptable to show "file unavailable" temporarily
- Can rebuild files from other sources

## Supabase Storage Metadata Replication

If using Supabase Storage at all, replicate the metadata tables:

```sql
-- Add to publication (on Primary)
ALTER PUBLICATION dr_publication ADD TABLE
    storage.buckets,
    storage.objects;
```

This ensures:
- Bucket configurations are replicated
- File metadata (paths, policies) are replicated
- Actual files are NOT replicated (separate concern)

## Comparison Table

| Approach                      | File Availability After Failover | Complexity | Cost   |
|-------------------------------|----------------------------------|------------|--------|
| External Storage (S3 CRR)     | Immediate                        | Medium     | Higher |
| External Storage (R2)         | Immediate                        | Low        | Lower  |
| Supabase + Dual-Write         | Immediate                        | High       | Higher |
| Supabase + Post-Failover Sync | Delayed                          | Medium     | Same   |
| Accept Unavailability         | Delayed/Manual                   | Low        | Same   |

## Recommendation

For most production deployments:

1. **Use external multi-region storage** (R2 for cost, S3 for features)
2. **Store only URLs in Supabase** (replicated automatically)
3. **CDN in front of storage** for performance

This approach:
- Completely decouples file availability from database failover
- Simplifies the failover procedure
- Reduces Supabase Storage costs
- Provides better global performance (CDN)

## Related Documents

- [Architecture Overview](architecture-overview.md)
- [Supabase Schema Replication](supabase-schema-replication.md)
