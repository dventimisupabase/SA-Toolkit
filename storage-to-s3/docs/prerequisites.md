# Prerequisites

Setup requirements for the Supabase Storage to S3 migration tool.

## Supabase CLI

### Installation

```bash
# macOS
brew install supabase/tap/supabase

# npm
npm install -g supabase

# Other: https://supabase.com/docs/guides/cli
```

### Link Project

```bash
# Login (opens browser)
supabase login

# Link to your project
supabase link --project-ref <your-project-ref>

# Verify
supabase storage ls --linked --experimental
```

Find your project ref in the Supabase dashboard URL: `https://supabase.com/dashboard/project/<project-ref>`

## AWS CLI

### Installation

```bash
# macOS
brew install awscli

# Other: https://aws.amazon.com/cli/
```

### Configuration

```bash
# Configure credentials
aws configure

# Or set environment variables
export AWS_ACCESS_KEY_ID=your-key
export AWS_SECRET_ACCESS_KEY=your-secret
export AWS_REGION=us-east-1
```

### Verify

```bash
# Check identity
aws sts get-caller-identity

# Test S3 access
aws s3 ls s3://your-bucket/
```

## AWS Permissions

The AWS credentials need these S3 permissions on the target bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::your-bucket",
        "arn:aws:s3:::your-bucket/*"
      ]
    }
  ]
}
```

## S3 Bucket Setup

```bash
# Create bucket (if needed)
aws s3 mb s3://your-bucket --region us-east-1

# Optional: Enable versioning
aws s3api put-bucket-versioning \
  --bucket your-bucket \
  --versioning-configuration Status=Enabled
```

## Checklist

- [ ] Supabase CLI installed (`supabase --version`)
- [ ] Supabase project linked (`supabase link`)
- [ ] AWS CLI installed (`aws --version`)
- [ ] AWS credentials configured (`aws sts get-caller-identity`)
- [ ] S3 bucket exists and accessible (`aws s3 ls s3://bucket/`)
- [ ] Sufficient disk space in temp directory for downloads
