import { Injectable, Logger, OnApplicationBootstrap, OnModuleDestroy } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { QueueService } from '../queue/queue.service';
import { describeDependencyError } from '../health/dependency-check';

export interface RecoveryResult {
  scanned: number;
  requeued: number;
  markedFailed: number;
  inFlight: number;
  inconsistent: number;
  errors: number;
}

const ACTIVE_STATES = new Set(['waiting', 'active', 'delayed', 'prioritized', 'waiting-children']);

function intFromEnv(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  return Number.isInteger(value) && value >= 0 ? value : fallback;
}

/**
 * PostgreSQL-backed queue recovery.
 *
 * PostgreSQL is the source of truth for stock checks; Redis only holds the
 * delivery mechanism. If Redis loses jobs (restore from an older backup, empty
 * Redis after a regional failover, FLUSHALL), PENDING/PROCESSING checks would
 * otherwise wait forever. This service periodically reconciles non-terminal
 * checks older than a grace period against BullMQ:
 *
 *   job missing          -> re-enqueue with jobId = stockCheck.id (idempotent)
 *   job failed           -> mark the check FAILED with the job's failure reason
 *                           (e.g. stalled more than the allowed limit after a
 *                           worker crash), so clients get a terminal status
 *   job waiting/active/… -> leave alone (BullMQ will deliver it)
 *   job completed        -> log: DB should already be COMPLETED (processor
 *                           commits before acknowledging)
 *
 * Safe to run concurrently from several backend instances: BullMQ ignores an
 * add for an existing job ID, and the FAILED transition is a conditional update.
 */
@Injectable()
export class StockCheckRecoveryService implements OnApplicationBootstrap, OnModuleDestroy {
  private readonly logger = new Logger(StockCheckRecoveryService.name);
  private timer: ReturnType<typeof setInterval> | undefined;
  private running = false;

  readonly intervalMs = intFromEnv('STOCK_CHECK_RECOVERY_INTERVAL_MS', 60_000);
  readonly staleAfterMs = intFromEnv('STOCK_CHECK_RECOVERY_STALE_AFTER_MS', 120_000);
  readonly batchSize = intFromEnv('STOCK_CHECK_RECOVERY_BATCH_SIZE', 100);

  constructor(
    private readonly prisma: PrismaService,
    private readonly queueService: QueueService,
  ) {}

  onApplicationBootstrap(): void {
    if (this.intervalMs === 0) {
      this.logger.log('Stock check recovery disabled (STOCK_CHECK_RECOVERY_INTERVAL_MS=0)');
      return;
    }
    this.timer = setInterval(() => void this.runOnce(), this.intervalMs);
    this.timer.unref();
    // First pass shortly after startup, so recovery happens without waiting a full interval.
    setTimeout(() => void this.runOnce(), Math.min(this.intervalMs, 10_000)).unref();
  }

  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /** Guarded wrapper: never overlaps itself and never throws. */
  async runOnce(): Promise<RecoveryResult | undefined> {
    if (this.running) return undefined;
    this.running = true;
    try {
      return await this.reconcile();
    } catch (err) {
      this.logger.warn(`Stock check recovery pass failed: ${describeDependencyError(err)}`);
      return undefined;
    } finally {
      this.running = false;
    }
  }

  async reconcile(now: Date = new Date()): Promise<RecoveryResult> {
    const cutoff = new Date(now.getTime() - this.staleAfterMs);
    const candidates = await this.prisma.stockCheck.findMany({
      where: { status: { in: ['PENDING', 'PROCESSING'] }, createdAt: { lte: cutoff } },
      orderBy: { createdAt: 'asc' },
      take: this.batchSize,
      select: { id: true, jobId: true, status: true },
    });

    const result: RecoveryResult = {
      scanned: candidates.length,
      requeued: 0,
      markedFailed: 0,
      inFlight: 0,
      inconsistent: 0,
      errors: 0,
    };

    for (const check of candidates) {
      try {
        const job = await this.queueService.getStockCheckJobState(check.id);

        if (!job) {
          if (check.jobId !== check.id) {
            // Legacy record enqueued with a Redis auto-increment ID: adopt the ID-based job ID.
            await this.prisma.stockCheck.updateMany({
              where: { id: check.id, status: { in: ['PENDING', 'PROCESSING'] } },
              data: { jobId: check.id },
            });
          }
          await this.queueService.addStockCheckJob(check.id);
          result.requeued++;
          this.logger.warn(`Re-enqueued ${check.status} stock check "${check.id}" (job missing from Redis)`);
        } else if (job.state === 'failed') {
          const reason = (job.failedReason || 'unknown reason').slice(0, 300);
          const updated = await this.prisma.stockCheck.updateMany({
            where: { id: check.id, status: { in: ['PENDING', 'PROCESSING'] } },
            data: { status: 'FAILED', error: `Job failed: ${reason}`, completedAt: new Date() },
          });
          result.markedFailed += updated.count;
          if (updated.count) this.logger.warn(`Marked stock check "${check.id}" FAILED: job failed (${reason})`);
        } else if (ACTIVE_STATES.has(job.state)) {
          result.inFlight++;
        } else {
          result.inconsistent++;
          this.logger.warn(`Stock check "${check.id}" is ${check.status} but its job is ${job.state}`);
        }
      } catch (err) {
        result.errors++;
        this.logger.warn(`Recovery of stock check "${check.id}" failed: ${describeDependencyError(err)}`);
      }
    }

    if (result.requeued || result.markedFailed || result.inconsistent || result.errors) {
      this.logger.log(`Stock check recovery: ${JSON.stringify(result)}`);
    }
    return result;
  }
}
