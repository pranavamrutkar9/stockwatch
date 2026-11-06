import * as dotenv from 'dotenv';
import { Worker } from 'bullmq';
import Redis from 'ioredis';
import { prisma } from '@stockwatch/database';
import { processStockCheckJob, StockCheckJobData } from './processor';

dotenv.config();

console.log('[Worker] StockWatch Background Worker process starting...');
console.log(`[Worker] Started at: ${new Date().toISOString()}`);
console.log(`[Worker] Process ID: ${process.pid}`);

const redisHost = process.env.REDIS_HOST || 'localhost';
const redisPort = parseInt(process.env.REDIS_PORT || '6379', 10);
const redisPassword = process.env.REDIS_PASSWORD || undefined;

console.log(`[Worker] Connecting to Redis at ${redisHost}:${redisPort}`);

const redisConnection = new Redis({
  host: redisHost,
  port: redisPort,
  password: redisPassword,
  maxRetriesPerRequest: null,
  enableReadyCheck: false,
  retryStrategy: (times) => {
    const delay = Math.min(times * 500, 3000);
    console.log(`[Worker] Reconnecting to Redis in ${delay}ms (attempt ${times})...`);
    return delay;
  },
});

redisConnection.on('connect', () => {
  console.log('[Worker] Connected to Redis successfully.');
});

redisConnection.on('error', (err) => {
  console.warn(`[Worker] Redis connection error: ${err.message}`);
});

const worker = new Worker<StockCheckJobData>(
  'stock-check',
  async (job) => {
    return processStockCheckJob(job);
  },
  {
    connection: redisConnection,
    concurrency: 2,
  },
);

worker.on('active', (job) => {
  console.log(`[Worker] Job ${job.id} active on worker.`);
});

worker.on('completed', (job) => {
  console.log(`[Worker] Job ${job.id} has successfully completed.`);
});

worker.on('failed', (job, err) => {
  console.error(`[Worker] Job ${job?.id} failed with error: ${err.message}`);
});

worker.on('error', (err) => {
  console.error(`[Worker] BullMQ Worker error: ${err.message}`);
});

let isShuttingDown = false;

async function shutdown(signal: string) {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.log(`[Worker] Received ${signal}. Gracefully shutting down worker...`);

  try {
    await worker.close();
    console.log('[Worker] BullMQ Worker closed.');
    await redisConnection.quit();
    console.log('[Worker] Redis connection closed.');
    await prisma.$disconnect();
    console.log('[Worker] Database disconnected.');
  } catch (err) {
    console.error(`[Worker] Error during shutdown: ${(err as Error).message}`);
  }

  console.log('[Worker] Graceful shutdown complete.');
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

console.log('[Worker] StockWatch Background Worker is active and consuming "stock-check" queue.');
