import { Injectable, OnModuleInit, OnModuleDestroy, Logger } from '@nestjs/common';
import { Queue } from 'bullmq';
import Redis from 'ioredis';
import { DEPENDENCY_CHECK_TIMEOUT_MS, DependencyHealthLog, withTimeout } from '../health/dependency-check';

@Injectable()
export class QueueService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(QueueService.name);
  private readonly healthLog = new DependencyHealthLog('Redis', this.logger);
  private stockCheckQueue!: Queue;
  private redisConnection!: Redis;

  onModuleInit() {
    const host = process.env.REDIS_HOST || 'localhost';
    const port = parseInt(process.env.REDIS_PORT || '6379', 10);
    const password = process.env.REDIS_PASSWORD || undefined;

    this.redisConnection = new Redis({
      host,
      port,
      password,
      maxRetriesPerRequest: null,
      enableReadyCheck: false,
      retryStrategy: (times) => {
        const delay = Math.min(times * 500, 3000);
        return delay;
      },
    });

    this.redisConnection.on('error', (err) => {
      this.logger.warn(`Redis connection error: ${err.message}`);
    });

    this.stockCheckQueue = new Queue('stock-check', {
      connection: this.redisConnection,
      defaultJobOptions: {
        attempts: 3,
        backoff: {
          type: 'exponential',
          delay: 1000,
        },
        removeOnComplete: { count: 100 },
        removeOnFail: false,
      },
    });

    this.logger.log(`StockCheck BullMQ queue initialized on ${host}:${port}`);
  }

  async onModuleDestroy() {
    if (this.stockCheckQueue) {
      await this.stockCheckQueue.close();
    }
    if (this.redisConnection) {
      await this.redisConnection.quit();
    }
    this.logger.log('Queue and Redis connections closed');
  }

  /**
   * Readiness probe. The shared connection uses `maxRetriesPerRequest: null`
   * (required by BullMQ), so a PING issued while Redis is down would wait
   * indefinitely; the timeout keeps /api/health responsive.
   */
  async isHealthy(): Promise<boolean> {
    try {
      if (!this.redisConnection) throw new Error('Redis connection not initialized');
      const pong = await withTimeout(this.redisConnection.ping(), DEPENDENCY_CHECK_TIMEOUT_MS, 'Redis PING');
      if (pong !== 'PONG') throw new Error(`Unexpected Redis PING response: ${pong}`);
      this.healthLog.success();
      return true;
    } catch (err) {
      this.healthLog.failure(err);
      return false;
    }
  }

  /**
   * Enqueues a stock check using the StockCheck ID as the BullMQ job ID.
   *
   * - Job IDs no longer depend on Redis' auto-increment counter, so they cannot
   *   collide with `stock_checks.jobId` (UNIQUE) after Redis is restored or
   *   replaced.
   * - Adding a job whose ID already exists in Redis is a no-op in BullMQ, so
   *   concurrent or repeated enqueue/recovery calls create at most one job.
   */
  async addStockCheckJob(stockCheckId: string): Promise<string> {
    const job = await this.stockCheckQueue.add('process-check', { stockCheckId }, { jobId: stockCheckId });
    this.logger.log(`Queued stock check job "${job.id}"`);
    return job.id as string;
  }

  /** Current BullMQ state of a stock check's job, or null if Redis has no such job. */
  async getStockCheckJobState(stockCheckId: string): Promise<{ state: string; failedReason?: string } | null> {
    const job = await this.stockCheckQueue.getJob(stockCheckId);
    if (!job) return null;
    const state = await job.getState();
    if (state === 'unknown') return null;
    return { state, failedReason: job.failedReason || undefined };
  }
}
