# Multi-Region Supabase HA & DR PRD

## Status

Draft

## Owner

Platform / Infrastructure

## Stakeholders

-   Application Engineering
-   SRE / Reliability
-   Security
-   Product (availability & SLA commitments)

------------------------------------------------------------------------

## 1. Problem Statement

Supabase projects are single-region for writes with no built-in
automatic cross-region failover. This document defines a deliberate,
single-writer, multi-region DR architecture that avoids split brain and
preserves Supabase primitives.

------------------------------------------------------------------------

## 2. Goals

-   Single authoritative write region
-   Warm standby in second region
-   Controlled failover with connection draining
-   HA story for DB, Realtime, Edge Functions, and Storage

Non-goals: - Active-active writes - Zero-RPO guarantees - Fully
automatic failover

------------------------------------------------------------------------

## 3. Architecture Summary

-   Project A (Primary)
-   Project B (Standby)
-   Self-hosted PgBouncer
-   One-way CDC
-   External multi-region object storage
-   Global active-region control flag

------------------------------------------------------------------------

## 4. Database Design

-   One writer at a time
-   Standby is read-only by default
-   CDC direction is explicit and never bidirectional

------------------------------------------------------------------------

## 5. PgBouncer

-   Stable endpoint for apps
-   PAUSE / RESUME used for switchover
-   Upstream DSN swapped during failover

------------------------------------------------------------------------

## 6. Storage

-   External object storage is canonical
-   Supabase DB stores metadata only
-   Optional best-effort mirroring if Supabase Storage is used

------------------------------------------------------------------------

## 7. Realtime

-   HA within a region is native
-   Cross-region failover requires client reconnect
-   No replication of realtime state

------------------------------------------------------------------------

## 8. Edge Functions

-   Deployed to both projects
-   DB access via PgBouncer
-   Routing controlled by active-region flag

------------------------------------------------------------------------

## 9. Failover Summary

1.  Pause PgBouncer
2.  Freeze old primary (if reachable)
3.  Flip active-region flag
4.  Promote standby
5.  Swap PgBouncer upstream
6.  Resume PgBouncer

------------------------------------------------------------------------

## 10. Success Criteria

-   No split brain
-   Predictable RTO/RPO
-   Repeatable and testable
