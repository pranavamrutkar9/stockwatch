/**
 * Integration tests against REAL PostgreSQL and Redis (isolated throwaway
 * containers started by scripts/test-integration.sh). Skipped unless
 * INTEGRATION_REDIS_HOST is set, so normal unit-test runs and CI are unaffected.
 *
 * The database connection uses the least-privilege runtime role
 * (stockwatch_app): every statement here must work without DDL/TRUNCATE.
 */
import Redis from 'ioredis';
import { Queue, Worker, UnrecoverableError } from 'bullmq';
import { PrismaService } from '../prisma/prisma.service';
import { QueueService } from '../queue/queue.service';
import { StockChecksService } from './stock-checks.service';
import { StockCheckRecoveryService } from './stock-check-recovery.service';

const enabled = Boolean(process.env.INTEGRATION_REDIS_HOST);
const describeIntegration = enabled ? describe : describe.skip;
jest.setTimeout(60_000);

const redisOptions = () => ({
  host: process.env.REDIS_HOST,
  port: Number(process.env.REDIS_PORT || 6379),
  password: process.env.REDIS_PASSWORD || undefined,
  maxRetriesPerRequest: null,
});

describeIntegration('Stock check job IDs and PostgreSQL-backed recovery (real Redis + PostgreSQL)', () => {
  let prisma: PrismaService;
  let queueService: QueueService;
  let stockChecks: StockChecksService;
  let recovery: StockCheckRecoveryService;
  let redis: Redis;
  let queue: Queue;

  const quiet = (svc: object) => {
    const logger = (svc as { logger: { log: () => void; warn: () => void } }).logger;
    jest.spyOn(logger, 'log').mockImplementation();
    jest.spyOn(logger, 'warn').mockImplementation();
  };

  const newQueueService = () => {
    const svc = new QueueService();
    quiet(svc);
    svc.onModuleInit();
    return svc;
  };

  const newRecovery = (q: QueueService) => {
    const svc = new StockCheckRecoveryService(prisma, q);
    quiet(svc);
    return svc;
  };

  beforeAll(async () => {
    process.env.STOCK_CHECK_RECOVERY_STALE_AFTER_MS = '0';
    prisma = new PrismaService();
    quiet(prisma);
    await prisma.onModuleInit();
    queueService = newQueueService();
    stockChecks = new StockChecksService(prisma, queueService);
    recovery = newRecovery(queueService);
    redis = new Redis(redisOptions());
    queue = new Queue('stock-check', { connection: redisOptions() });
  });

  beforeEach(async () => {
    await redis.flushdb();
    // DML only (runtime role has no TRUNCATE).
    await prisma.stockAlert.deleteMany();
    await prisma.stockCheck.deleteMany();
    await prisma.inventoryItem.deleteMany();
  });

  afterAll(async () => {
    await queue.close();
    await queueService.onModuleDestroy();
    await redis.quit();
    await prisma.$disconnect();
  });

  const waitingJobIds = async () => (await queue.getJobs(['waiting'])).map((j) => j.id).sort();

  it('enqueue stores jobId = record ID and creates a BullMQ job with that ID', async () => {
    const result = await stockChecks.enqueue();
    expect(result.jobId).toBe(result.id);
    const row = await prisma.stockCheck.findUniqueOrThrow({ where: { id: result.id } });
    expect(row.jobId).toBe(result.id);
    expect(await waitingJobIds()).toEqual([result.id]);
  });

  it('enqueue keeps working after Redis loss even when legacy numeric job IDs exist (previous collision bug)', async () => {
    // Legacy rows created with Redis auto-increment IDs "1" and "2".
    await prisma.stockCheck.create({ data: { jobId: '1', status: 'COMPLETED' } });
    await prisma.stockCheck.create({ data: { jobId: '2', status: 'COMPLETED' } });
    await redis.flushdb(); // Redis counter reset; old code would now produce job "1" and hit UNIQUE(jobId)

    const results = await Promise.all([stockChecks.enqueue(), stockChecks.enqueue()]);
    for (const r of results) expect(r.status).toBe('PENDING');
    expect(await prisma.stockCheck.count({ where: { status: 'FAILED' } })).toBe(0);
  });

  it('20 concurrent enqueues produce 20 rows and 20 distinct jobs', async () => {
    const results = await Promise.all(Array.from({ length: 20 }, () => stockChecks.enqueue()));
    const ids = results.map((r) => r.id).sort();
    expect(new Set(ids).size).toBe(20);
    expect(await waitingJobIds()).toEqual(ids);
    expect(await prisma.stockCheck.count({ where: { status: 'PENDING' } })).toBe(20);
  });

  it('after Redis loss, recovery re-enqueues PENDING and PROCESSING checks (and adopts legacy job IDs)', async () => {
    const pending = await stockChecks.enqueue();
    const processing = await stockChecks.enqueue();
    await prisma.stockCheck.update({ where: { id: processing.id }, data: { status: 'PROCESSING', startedAt: new Date() } });
    const legacy = await prisma.stockCheck.create({ data: { jobId: '7', status: 'PENDING' } });
    const done = await prisma.stockCheck.create({ data: { jobId: '8', status: 'COMPLETED' } });

    await redis.flushdb(); // simulate Redis data loss
    expect(await waitingJobIds()).toEqual([]);

    const result = await recovery.reconcile();
    expect(result).toMatchObject({ scanned: 3, requeued: 3, errors: 0 });
    expect(await waitingJobIds()).toEqual([pending.id, processing.id, legacy.id].sort());
    expect((await prisma.stockCheck.findUniqueOrThrow({ where: { id: legacy.id } })).jobId).toBe(legacy.id);
    expect((await prisma.stockCheck.findUniqueOrThrow({ where: { id: done.id } })).jobId).toBe('8');

    // Second pass is a no-op: jobs now exist.
    expect(await recovery.reconcile()).toMatchObject({ requeued: 0, inFlight: 3 });
  });

  it('concurrent recovery from three backend instances creates exactly one job per check', async () => {
    const checks = await Promise.all(Array.from({ length: 10 }, () => stockChecks.enqueue()));
    await redis.flushdb();

    const instances = [newQueueService(), newQueueService(), newQueueService()];
    const recoveries = instances.map(newRecovery);
    await Promise.all([...recoveries, ...recoveries].map((r) => r.reconcile()));

    expect(await waitingJobIds()).toEqual(checks.map((c) => c.id).sort());
    expect(await queue.count()).toBe(10);
    await Promise.all(instances.map((q) => q.onModuleDestroy()));
  });

  it('a check whose job permanently failed (e.g. stalled limit after worker crashes) is marked FAILED', async () => {
    const check = await stockChecks.enqueue();
    await prisma.stockCheck.update({ where: { id: check.id }, data: { status: 'PROCESSING' } });

    const failed = new Promise<void>((resolve) => {
      const worker = new Worker(
        'stock-check',
        async () => {
          throw new UnrecoverableError('job stalled more than allowable limit');
        },
        { connection: redisOptions(), autorun: true },
      );
      worker.on('failed', () => void worker.close().then(resolve));
    });
    await failed;

    const result = await recovery.reconcile();
    expect(result.markedFailed).toBe(1);
    const row = await prisma.stockCheck.findUniqueOrThrow({ where: { id: check.id } });
    expect(row.status).toBe('FAILED');
    expect(row.error).toContain('job stalled more than allowable limit');
  });

  it('does not touch checks newer than the grace period', async () => {
    const svc = newRecovery(queueService);
    Object.defineProperty(svc, 'staleAfterMs', { value: 60_000 });
    await stockChecks.enqueue();
    await redis.flushdb();
    expect(await svc.reconcile()).toMatchObject({ scanned: 0, requeued: 0 });
  });
});
