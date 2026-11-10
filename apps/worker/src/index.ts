import * as dotenv from 'dotenv';
import { Worker } from 'bullmq';
import Redis from 'ioredis';
import { prisma } from '@stockwatch/database';
import { processStockCheckJob, StockCheckJobData } from './processor';
import { writeFileSync, unlinkSync } from 'node:fs';

dotenv.config();

const READY_FILE = '/tmp/stockwatch-worker-ready';
const STARTUP_TIMEOUT = 20000;

let redisConnection: Redis | undefined;
let worker: Worker<StockCheckJobData> | undefined;
let isShuttingDown = false;

function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  operation: string,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;

  const timeout = new Promise<T>((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`${operation} timed out after ${timeoutMs}ms`)),
      timeoutMs,
    );
  });

  return Promise.race([promise, timeout]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

function removeReadinessFile() {
  try {
    unlinkSync(READY_FILE);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.error('[Worker] Could not remove readiness marker:', error);
    }
  }
}

async function closeRedis() {
  if (!redisConnection) return;

  try {
    await withTimeout(redisConnection.quit(), 5000, 'Redis shutdown');
  } catch (error) {
    console.error('[Worker] Redis graceful shutdown failed:', error);
    redisConnection.disconnect();
  }
}

async function shutdown(signal: string) {
  if (isShuttingDown) return;
  isShuttingDown = true;

  removeReadinessFile();
  console.log(`[Worker] Received ${signal}. Starting graceful shutdown...`);

  if (worker) {
    try {
      await withTimeout(worker.close(), 20000, 'BullMQ shutdown');
      console.log('[Worker] BullMQ worker closed.');
    } catch (error) {
      console.error('[Worker] BullMQ shutdown failed:', error);
    }
  }

  await closeRedis();

  try {
    await withTimeout(prisma.$disconnect(), 5000, 'Prisma shutdown');
    console.log('[Worker] Database disconnected.');
  } catch (error) {
    console.error('[Worker] Prisma shutdown failed:', error);
  }

  console.log('[Worker] Shutdown complete.');
}

async function startWorker() {
  console.log('[Worker] Starting StockWatch background worker...');

  const redisUrl = process.env.REDIS_URL;
  const redisHost = process.env.REDIS_HOST || 'localhost';
  const redisPort = Number(process.env.REDIS_PORT || 6379);
  const redisPassword = process.env.REDIS_PASSWORD || undefined;

  if (!redisUrl && (!Number.isInteger(redisPort) || redisPort < 1 || redisPort > 65535)) {
    throw new Error('Invalid REDIS_PORT configuration.');
  }

  if (!process.env.DATABASE_URL) {
    throw new Error('DATABASE_URL is required.');
  }

  redisConnection = redisUrl
    ? new Redis(redisUrl, {
        lazyConnect: true,
        maxRetriesPerRequest: null,
        retryStrategy: (times) => Math.min(times * 500, 3000),
      })
    : new Redis({
        host: redisHost,
        port: redisPort,
        password: redisPassword,
        lazyConnect: true,
        maxRetriesPerRequest: null,
        retryStrategy: (times) => Math.min(times * 500, 3000),
      });

  redisConnection.on('error', (error) => {
    console.error(`[Worker] Redis error: ${error.message}`);
  });

  console.log('[Worker] Checking Redis connectivity...');
  await withTimeout(redisConnection.connect(), STARTUP_TIMEOUT, 'Redis connection');
  if (isShuttingDown) throw new Error('Startup interrupted by shutdown.');

  const redisPing = await withTimeout(
    redisConnection.ping(),
    5000,
    'Redis PING',
  );

  if (redisPing !== 'PONG') {
    throw new Error(`Unexpected Redis PING response: ${redisPing}`);
  }

  console.log('[Worker] Redis readiness check passed.');

  console.log('[Worker] Checking PostgreSQL/RDS connectivity...');
  await withTimeout(prisma.$connect(), STARTUP_TIMEOUT, 'Prisma connection');

  await withTimeout(
    prisma.$queryRaw`SELECT 1`,
    5000,
    'Database readiness query',
  );

  console.log('[Worker] PostgreSQL/RDS readiness check passed.');
  if (isShuttingDown) throw new Error('Startup interrupted by shutdown.');

  worker = new Worker<StockCheckJobData>(
    'stock-check',
    async (job) => processStockCheckJob(job),
    {
      connection: redisConnection,
      concurrency: Number(process.env.WORKER_CONCURRENCY || 2),
    },
  );

  worker.on('active', (job) => {
    console.log(`[Worker] Job ${job.id} active.`);
  });

  worker.on('completed', (job) => {
    console.log(`[Worker] Job ${job.id} completed.`);
  });

  worker.on('failed', (job, error) => {
    console.error(`[Worker] Job ${job?.id} failed: ${error.message}`);
  });

  worker.on('error', (error) => {
    console.error(`[Worker] BullMQ error: ${error.message}`);
  });

  await withTimeout(worker.waitUntilReady(), STARTUP_TIMEOUT, 'BullMQ readiness');
  if (isShuttingDown) throw new Error('Startup interrupted by shutdown.');

  if (isShuttingDown) {
    throw new Error('Worker startup interrupted by shutdown.');
  }

  writeFileSync(READY_FILE, `${process.pid}\n`, { mode: 0o644 });

  console.log('[Worker] WORKER_READY');
  console.log('[Worker] StockWatch worker is active and consuming stock-check jobs.');
}

process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));

startWorker().catch(async (error) => {
  removeReadinessFile();
  console.error('[Worker] STARTUP FAILED:', error);

  isShuttingDown = true;

  if (worker) {
    try {
      await withTimeout(worker.close(), 5000, 'Worker cleanup');
    } catch (cleanupError) {
      console.error('[Worker] Worker cleanup failed:', cleanupError);
    }
  }

  await closeRedis();

  try {
    await withTimeout(prisma.$disconnect(), 5000, 'Prisma cleanup');
  } catch (cleanupError) {
    console.error('[Worker] Database cleanup failed:', cleanupError);
  }

  process.exitCode = 1;
});
