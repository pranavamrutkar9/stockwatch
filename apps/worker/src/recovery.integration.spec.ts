/**
 * Integration tests against REAL PostgreSQL and Redis (isolated throwaway
 * containers started by scripts/test-integration.sh). Skipped unless
 * INTEGRATION_REDIS_HOST is set.
 *
 * Covers at-least-once delivery hazards: duplicate/concurrent delivery,
 * redelivery after completion, BullMQ retries, and a worker process killed
 * with SIGKILL mid-job (stalled-job recovery by another worker).
 * The database connection uses the least-privilege runtime role.
 */
import { spawn, ChildProcess } from 'node:child_process';
import { Job, Queue, Worker } from 'bullmq';
import Redis from 'ioredis';
import { prisma } from '@stockwatch/database';
import { processStockCheckJob, StockCheckJobData } from './processor';

const enabled = Boolean(process.env.INTEGRATION_REDIS_HOST);
const describeIntegration = enabled ? describe : describe.skip;
jest.setTimeout(60_000);

const connection = () => ({
  host: process.env.REDIS_HOST,
  port: Number(process.env.REDIS_PORT || 6379),
  password: process.env.REDIS_PASSWORD || undefined,
  maxRetriesPerRequest: null,
});

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function waitFor<T>(fn: () => Promise<T | undefined | null | false>, timeoutMs = 30_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await fn();
    if (value) return value as T;
    if (Date.now() > deadline) throw new Error('waitFor timed out');
    await sleep(200);
  }
}

describeIntegration('Worker delivery semantics (real Redis + PostgreSQL)', () => {
  let redis: Redis;
  let queue: Queue<StockCheckJobData>;
  const workers: Worker[] = [];
  const children: ChildProcess[] = [];

  const fakeJob = (id: string, attemptsMade = 0, attempts = 3) =>
    ({ id, data: { stockCheckId: id }, attemptsMade, opts: { attempts } }) as unknown as Job<StockCheckJobData>;

  const newCheck = () => prisma.stockCheck.create({ data: { jobId: 'tmp', status: 'PENDING' } }).then((c) =>
    prisma.stockCheck.update({ where: { id: c.id }, data: { jobId: c.id } }),
  );

  beforeAll(async () => {
    jest.spyOn(console, 'log').mockImplementation();
    jest.spyOn(console, 'warn').mockImplementation();
    jest.spyOn(console, 'error').mockImplementation();
    redis = new Redis(connection());
    queue = new Queue('stock-check', { connection: connection() });
  });

  beforeEach(async () => {
    await redis.flushdb();
    await prisma.stockAlert.deleteMany();
    await prisma.stockCheck.deleteMany();
    await prisma.inventoryItem.deleteMany();
    await prisma.inventoryItem.createMany({
      data: [
        { name: 'Mouse', sku: 'IT-M', category: 'A', quantity: 3, minQuantity: 10 }, // low
        { name: 'Keyboard', sku: 'IT-K', category: 'A', quantity: 20, minQuantity: 5 }, // healthy
        { name: 'Hub', sku: 'IT-H', category: 'A', quantity: 4, minQuantity: 4 }, // low (boundary)
      ],
    });
  });

  afterEach(async () => {
    for (const child of children.splice(0)) child.kill('SIGKILL');
    await Promise.all(workers.splice(0).map((w) => w.close(true)));
  });

  afterAll(async () => {
    await queue.close();
    await redis.quit();
    await prisma.$disconnect();
  });

  it('end-to-end: a real BullMQ worker completes the check with one alert per low-stock item', async () => {
    const check = await newCheck();
    workers.push(new Worker('stock-check', (job) => processStockCheckJob(job, { simulateFailure: false }), { connection: connection() }));
    await queue.add('process-check', { stockCheckId: check.id }, { jobId: check.id });

    const done = await waitFor(async () => {
      const row = await prisma.stockCheck.findUnique({ where: { id: check.id } });
      return row?.status === 'COMPLETED' && row;
    });
    expect(done).toMatchObject({ totalChecked: 3, lowStockCount: 2, error: null });
    expect(await prisma.stockAlert.count({ where: { stockCheckId: check.id } })).toBe(2);
  });

  it('duplicate concurrent delivery (5 parallel executions) yields one COMPLETED result and no duplicate alerts', async () => {
    const check = await newCheck();
    const results = await Promise.allSettled(
      Array.from({ length: 5 }, () => processStockCheckJob(fakeJob(check.id), { simulateFailure: false })),
    );
    expect(results.filter((r) => r.status === 'rejected')).toEqual([]);
    const row = await prisma.stockCheck.findUniqueOrThrow({ where: { id: check.id } });
    expect(row).toMatchObject({ status: 'COMPLETED', totalChecked: 3, lowStockCount: 2 });
    expect(await prisma.stockAlert.count({ where: { stockCheckId: check.id } })).toBe(2);
  });

  /**
   * Deterministic interleavings (no timing assumptions). A competing delivery's
   * transaction is held open at a chosen point; the test proves the processor
   * is actually blocked on a row lock (pg_stat_activity wait_event_type = 'Lock')
   * before releasing the competitor.
   */
  async function heldTransaction(work: (tx: Parameters<Parameters<typeof prisma.$transaction>[0]>[0]) => Promise<void>) {
    let release!: () => void;
    let ready!: () => void;
    const isReady = new Promise<void>((r) => (ready = r));
    const done = prisma.$transaction(
      async (tx) => {
        await work(tx);
        ready();
        await new Promise<void>((r) => (release = r));
      },
      { timeout: 30_000, maxWait: 10_000 },
    );
    await isReady;
    return { release: () => release(), done };
  }

  const blockedOnLock = () =>
    waitFor(async () => {
      const rows = await prisma.$queryRaw<{ n: bigint }[]>`
        SELECT count(*) AS n FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()`;
      return Number(rows[0].n) > 0;
    }, 10_000);

  const lowItems = async () => (await prisma.inventoryItem.findMany()).filter((i) => i.quantity <= i.minQuantity);

  it('forced interleaving A: competing transaction holds uncommitted alert rows -> delivery blocks, then completes without error or duplicates', async () => {
    const check = await newCheck();
    const items = await lowItems();
    const competitor = await heldTransaction(async (tx) => {
      await tx.stockAlert.createMany({
        data: items.map((i) => ({ stockCheckId: check.id, inventoryItemId: i.id, quantity: i.quantity, minQuantity: i.minQuantity, message: 'competitor' })),
      });
    });

    const delivery = processStockCheckJob(fakeJob(check.id), { simulateFailure: false });
    await blockedOnLock(); // the processor is waiting on the unique index entries held by the competitor
    competitor.release();
    await competitor.done;

    const result = await delivery;
    expect(result).toMatchObject({ status: 'COMPLETED', lowStockCount: 2 });
    expect(await prisma.stockAlert.count({ where: { stockCheckId: check.id } })).toBe(2);
  });

  it('control for A: the previous per-row Prisma upsert also survives this interleaving (native ON CONFLICT DO UPDATE) - the old alert path was not racy', async () => {
    const check = await newCheck();
    const [item] = await lowItems();
    const competitor = await heldTransaction(async (tx) => {
      await tx.stockAlert.create({
        data: { stockCheckId: check.id, inventoryItemId: item.id, quantity: item.quantity, minQuantity: item.minQuantity, message: 'competitor' },
      });
    });
    const legacyUpsert = prisma.stockAlert
      .upsert({
        where: { stockCheckId_inventoryItemId: { stockCheckId: check.id, inventoryItemId: item.id } },
        create: { stockCheckId: check.id, inventoryItemId: item.id, quantity: item.quantity, minQuantity: item.minQuantity, message: 'legacy' },
        update: { message: 'legacy' },
      })
      .then(() => 'ok', (e: { code?: string }) => `error ${e.code ?? 'unknown'}`);
    await blockedOnLock();
    competitor.release();
    await competitor.done;
    // Finding (2026-11-10): Prisma 6 executes this compound-unique upsert as a native
    // INSERT ... ON CONFLICT DO UPDATE, so it does not raise P2002 under contention.
    expect(await legacyUpsert).toBe('ok');
  });

  it('forced interleaving B: competing delivery holds an uncommitted COMPLETED transition -> claim blocks, then skips without recomputing', async () => {
    const check = await newCheck();
    const competitorCompletedAt = new Date('2026-01-01T00:00:00Z');
    const competitor = await heldTransaction(async (tx) => {
      await tx.stockCheck.update({
        where: { id: check.id },
        data: { status: 'COMPLETED', totalChecked: 3, lowStockCount: 2, completedAt: competitorCompletedAt },
      });
    });

    // findUnique sees the committed PENDING state, so the processor proceeds to its claim and blocks there.
    const delivery = processStockCheckJob(fakeJob(check.id), { simulateFailure: false });
    await blockedOnLock();
    competitor.release();
    await competitor.done;

    const result = await delivery;
    expect(result.status).toBe('COMPLETED');
    expect(result.completedAt?.toISOString()).toBe(competitorCompletedAt.toISOString()); // not overwritten
    expect(await prisma.stockAlert.count({ where: { stockCheckId: check.id } })).toBe(0); // no recompute
  });

  it('redelivery after completion is a no-op even if inventory changed since', async () => {
    const check = await newCheck();
    const first = await processStockCheckJob(fakeJob(check.id), { simulateFailure: false });

    await prisma.inventoryItem.update({ where: { sku: 'IT-K' }, data: { quantity: 0 } }); // would add an alert
    const again = await processStockCheckJob(fakeJob(check.id), { simulateFailure: false });

    expect(again.completedAt?.getTime()).toBe(first.completedAt?.getTime());
    expect(again.lowStockCount).toBe(2);
    expect(await prisma.stockAlert.count({ where: { stockCheckId: check.id } })).toBe(2);
  });

  it('BullMQ retry: a failed first attempt leaves the check PROCESSING (not FAILED); the retry completes it', async () => {
    const check = await newCheck();
    let calls = 0;
    const statusAfterFirstFailure = new Promise<{ status: string; error: string | null }>((resolve) => {
      const worker = new Worker(
        'stock-check',
        (job) => processStockCheckJob(job, { simulateFailure: ++calls === 1 }),
        { connection: connection() },
      );
      worker.on('failed', async () => {
        const row = await prisma.stockCheck.findUniqueOrThrow({ where: { id: check.id } });
        resolve({ status: row.status, error: row.error });
      });
      workers.push(worker);
    });
    await queue.add('process-check', { stockCheckId: check.id }, { jobId: check.id, attempts: 2, backoff: { type: 'fixed', delay: 200 } });

    const afterFirst = await statusAfterFirstFailure;
    expect(afterFirst.status).toBe('PROCESSING');
    expect(afterFirst.error).toMatch(/^Attempt 1\/2 failed, retrying: /);

    const done = await waitFor(async () => {
      const row = await prisma.stockCheck.findUnique({ where: { id: check.id } });
      return row?.status === 'COMPLETED' && row;
    });
    expect(done.error).toBeNull();
    expect(calls).toBe(2);
  });

  it('BullMQ retries exhausted: the final failed attempt marks the check FAILED', async () => {
    const check = await newCheck();
    workers.push(new Worker('stock-check', (job) => processStockCheckJob(job, { simulateFailure: true }), { connection: connection() }));
    await queue.add('process-check', { stockCheckId: check.id }, { jobId: check.id, attempts: 2, backoff: { type: 'fixed', delay: 100 } });

    const row = await waitFor(async () => {
      const r = await prisma.stockCheck.findUnique({ where: { id: check.id } });
      return r?.status === 'FAILED' && r;
    });
    expect(row.error).toBe('Simulated worker processing failure for demonstration purposes');
    expect(await queue.getJobState(check.id)).toBe('failed');
  });

  it('worker killed with SIGKILL mid-job: the stalled job is recovered by another worker and completed once', async () => {
    const check = await newCheck();
    await queue.add('process-check', { stockCheckId: check.id }, { jobId: check.id });

    // Worker A: separate OS process that takes the job, marks it PROCESSING (as the
    // real processor's first step does) and then hangs until it is killed.
    const childSource = `
      const { Worker } = require(process.env.BULLMQ_PATH);
      new Worker('stock-check', async (job) => {
        process.send({ type: 'active', id: job.id });
        await new Promise(() => {});
      }, {
        connection: JSON.parse(process.env.REDIS_CONN),
        lockDuration: 2000,
        stalledInterval: 1000,
      });`;
    const child = spawn(process.execPath, ['-e', childSource], {
      stdio: ['ignore', 'ignore', 'inherit', 'ipc'],
      env: { ...process.env, BULLMQ_PATH: require.resolve('bullmq'), REDIS_CONN: JSON.stringify(connection()) },
    });
    children.push(child);

    await new Promise<void>((resolve) => child.on('message', (m: { type: string }) => m.type === 'active' && resolve()));
    await prisma.stockCheck.update({ where: { id: check.id }, data: { status: 'PROCESSING', startedAt: new Date() } });
    expect(await queue.getJobState(check.id)).toBe('active');

    child.kill('SIGKILL');
    await new Promise((r) => child.on('exit', r));
    const killedAt = Date.now();

    // Worker B: the real processor. Its stalled-job checker finds the expired lock and re-delivers.
    let deliveries = 0;
    workers.push(
      new Worker(
        'stock-check',
        (job) => {
          deliveries++;
          return processStockCheckJob(job, { simulateFailure: false });
        },
        { connection: connection(), lockDuration: 2000, stalledInterval: 1000 },
      ),
    );

    const done = await waitFor(async () => {
      const row = await prisma.stockCheck.findUnique({ where: { id: check.id } });
      return row?.status === 'COMPLETED' && row;
    });
    const recoveredInMs = Date.now() - killedAt;

    expect(done).toMatchObject({ totalChecked: 3, lowStockCount: 2 });
    expect(await prisma.stockAlert.count({ where: { stockCheckId: check.id } })).toBe(2);
    expect(deliveries).toBe(1);
    expect(await queue.getJobState(check.id)).toBe('completed');
    // Informational: recovery latency is bounded by lockDuration + stalledInterval.
    process.stdout.write(`\n[evidence] SIGKILL stalled-job recovery completed in ${recoveredInMs} ms\n`);
  });
});
