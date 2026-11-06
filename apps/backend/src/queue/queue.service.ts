import { Injectable, OnModuleInit, OnModuleDestroy, Logger } from '@nestjs/common';
import { Queue } from 'bullmq';
import Redis from 'ioredis';

@Injectable()
export class QueueService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(QueueService.name);
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

  async isHealthy(): Promise<boolean> {
    try {
      if (!this.redisConnection) return false;
      const pong = await this.redisConnection.ping();
      return pong === 'PONG';
    } catch {
      return false;
    }
  }

  async addStockCheckJob(stockCheckId: string): Promise<string> {
    const job = await this.stockCheckQueue.add('process-check', { stockCheckId });
    this.logger.log(`Queued stock check job "${job.id}" for record "${stockCheckId}"`);
    return job.id as string;
  }
}
