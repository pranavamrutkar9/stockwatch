# 06 — Redis and Queue Recovery

PostgreSQL is the source of truth; Redis holds only the delivery mechanism. The design goal is **zero lost accepted stock checks** even when Redis data is lost.

| Mechanism | Detail | Status |
|---|---|---|
| Redis persistence | AOF `everysec` on volume `stockwatch_redis_data`; recreation preserved all persistent keys | **Production verified** (2026-11-10 recovery, Redis recreated in 5 s) |
| Redis auth healthcheck | requires `PONG` (old check reported healthy on `WRONGPASS`) | **Production verified** |
| Job ID = stock-check ID | no collision with `stock_checks.jobId UNIQUE` after Redis reset; BullMQ de-duplicates repeated adds | **Production verified** (job `825a658d…`); mutation test: old code → 6/7 integration tests fail |
| PostgreSQL-backed reconstruction | `StockCheckRecoveryService` (backend) re-enqueues PENDING/PROCESSING checks whose job is missing; marks checks FAILED when their job permanently failed; safe from multiple instances | **Code implemented and tested**; **Local simulation verified** (S3, S5); active in production (periodic scan observed) |
| At-least-once safety | COMPLETED never recomputed; alerts + COMPLETED in one transaction with `ON CONFLICT DO NOTHING`; non-final failures stay PROCESSING | **Code implemented and tested** incl. forced transaction interleavings proven blocked via `pg_stat_activity` |
| Worker crash | BullMQ stalled-job recovery; SIGKILLed worker's job completed once by another worker | **Local simulation verified** (integration test ≈ 2–3 s; S4 ≈ 61 s with default 30 s lock) |
| Redis backup/restore | `redis-backup.sh` (BGSAVE + archive + verification in network-less Redis), `redis-restore.sh` (token, checksum, safety copy, key-set verification) | **Local simulation verified** (test suite) |

Notes:
- After a SIGKILL, in-flight jobs wait for BullMQ's `lockDuration` (30 s) plus the stalled check (30 s) — up to ≈ 60 s. A graceful stop (SIGTERM) avoids this.
- The BullMQ id counter still increments on every add even with custom job IDs (observed 6 → 7 in production); it is not used for IDs.
