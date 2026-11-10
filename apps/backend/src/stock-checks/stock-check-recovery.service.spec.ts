import { StockCheckRecoveryService } from './stock-check-recovery.service';
import { PrismaService } from '../prisma/prisma.service';
import { QueueService } from '../queue/queue.service';

type Check = { id: string; jobId: string; status: 'PENDING' | 'PROCESSING' };

function setup(checks: Check[], jobStates: Record<string, { state: string; failedReason?: string } | null>) {
  const prisma = {
    stockCheck: {
      findMany: jest.fn().mockResolvedValue(checks),
      updateMany: jest.fn().mockResolvedValue({ count: 1 }),
    },
  };
  const queue = {
    getStockCheckJobState: jest.fn(async (id: string) => jobStates[id] ?? null),
    addStockCheckJob: jest.fn(async (id: string) => id),
  };
  const service = new StockCheckRecoveryService(
    prisma as unknown as PrismaService,
    queue as unknown as QueueService,
  );
  jest.spyOn((service as unknown as { logger: { warn: () => void } }).logger, 'warn').mockImplementation();
  jest.spyOn((service as unknown as { logger: { log: () => void } }).logger, 'log').mockImplementation();
  return { service, prisma, queue };
}

describe('StockCheckRecoveryService.reconcile', () => {
  it('only scans non-terminal checks older than the grace period', async () => {
    const { service, prisma } = setup([], {});
    const now = new Date('2026-11-10T20:00:00Z');
    await service.reconcile(now);
    const { where } = prisma.stockCheck.findMany.mock.calls[0][0];
    expect(where.status).toEqual({ in: ['PENDING', 'PROCESSING'] });
    expect(where.createdAt.lte.getTime()).toBe(now.getTime() - service.staleAfterMs);
  });

  it('re-enqueues checks whose job is missing from Redis, using the check ID as job ID', async () => {
    const { service, queue } = setup(
      [
        { id: 'a', jobId: 'a', status: 'PENDING' },
        { id: 'b', jobId: 'b', status: 'PROCESSING' },
      ],
      {},
    );
    const result = await service.reconcile();
    expect(queue.addStockCheckJob.mock.calls).toEqual([['a'], ['b']]);
    expect(result).toMatchObject({ scanned: 2, requeued: 2 });
  });

  it('adopts the ID-based job ID for legacy records before re-enqueueing', async () => {
    const { service, prisma, queue } = setup([{ id: 'legacy', jobId: '3', status: 'PENDING' }], {});
    await service.reconcile();
    expect(prisma.stockCheck.updateMany).toHaveBeenCalledWith({
      where: { id: 'legacy', status: { in: ['PENDING', 'PROCESSING'] } },
      data: { jobId: 'legacy' },
    });
    expect(queue.addStockCheckJob).toHaveBeenCalledWith('legacy');
  });

  it('leaves checks with waiting/active/delayed jobs alone', async () => {
    const { service, queue, prisma } = setup(
      [
        { id: 'w', jobId: 'w', status: 'PENDING' },
        { id: 'x', jobId: 'x', status: 'PROCESSING' },
        { id: 'd', jobId: 'd', status: 'PENDING' },
      ],
      { w: { state: 'waiting' }, x: { state: 'active' }, d: { state: 'delayed' } },
    );
    const result = await service.reconcile();
    expect(queue.addStockCheckJob).not.toHaveBeenCalled();
    expect(prisma.stockCheck.updateMany).not.toHaveBeenCalled();
    expect(result.inFlight).toBe(3);
  });

  it('marks checks FAILED (conditionally) when their job has permanently failed', async () => {
    const { service, prisma } = setup([{ id: 'f', jobId: 'f', status: 'PROCESSING' }], {
      f: { state: 'failed', failedReason: 'job stalled more than allowable limit' },
    });
    const result = await service.reconcile();
    expect(prisma.stockCheck.updateMany).toHaveBeenCalledWith({
      where: { id: 'f', status: { in: ['PENDING', 'PROCESSING'] } },
      data: expect.objectContaining({ status: 'FAILED', error: 'Job failed: job stalled more than allowable limit' }),
    });
    expect(result.markedFailed).toBe(1);
  });

  it('continues after a per-check error and reports it', async () => {
    const { service, queue } = setup(
      [
        { id: 'bad', jobId: 'bad', status: 'PENDING' },
        { id: 'good', jobId: 'good', status: 'PENDING' },
      ],
      {},
    );
    queue.addStockCheckJob.mockRejectedValueOnce(new Error('READONLY'));
    const result = await service.reconcile();
    expect(result).toMatchObject({ errors: 1, requeued: 1 });
  });

  it('runOnce never overlaps and never throws', async () => {
    const { service, prisma } = setup([], {});
    let release!: () => void;
    prisma.stockCheck.findMany.mockReturnValueOnce(new Promise((r) => (release = () => r([]))));
    const first = service.runOnce();
    await expect(service.runOnce()).resolves.toBeUndefined();
    release();
    await expect(first).resolves.toMatchObject({ scanned: 0 });
    prisma.stockCheck.findMany.mockRejectedValueOnce(new Error('P1001 unreachable'));
    await expect(service.runOnce()).resolves.toBeUndefined();
  });
});
