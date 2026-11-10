import { isFinalAttempt, processStockCheckJob } from './processor';
import { prisma } from '@stockwatch/database';
import { Job } from 'bullmq';

jest.mock('@stockwatch/database', () => {
  const client = {
    stockCheck: {
      findUnique: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
    },
    inventoryItem: {
      findMany: jest.fn(),
    },
    stockAlert: {
      createMany: jest.fn(),
    },
    $transaction: jest.fn(),
  };
  // Interactive transaction: run the callback against the same mocked client.
  client.$transaction.mockImplementation((fn: (tx: typeof client) => unknown) => fn(client));
  return { prisma: client };
});

type MockedPrisma = {
  stockCheck: { findUnique: jest.Mock; update: jest.Mock; updateMany: jest.Mock };
  inventoryItem: { findMany: jest.Mock };
  stockAlert: { createMany: jest.Mock };
  $transaction: jest.Mock;
};
const db = prisma as unknown as MockedPrisma;

const job = (overrides: Partial<{ attemptsMade: number; attempts: number }> = {}) =>
  ({
    id: 'check-uuid-1',
    data: { stockCheckId: 'check-uuid-1' },
    attemptsMade: overrides.attemptsMade ?? 0,
    opts: overrides.attempts ? { attempts: overrides.attempts } : {},
  }) as unknown as Job<{ stockCheckId: string }>;

const ITEMS = [
  { id: 'item-1', name: 'Mouse', sku: 'M01', quantity: 3, minQuantity: 10 }, // low (3 <= 10)
  { id: 'item-2', name: 'Keyboard', sku: 'K01', quantity: 20, minQuantity: 5 }, // healthy
  { id: 'item-3', name: 'USB Hub', sku: 'U01', quantity: 4, minQuantity: 4 }, // low (4 <= 4)
];

describe('Worker processStockCheckJob', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    db.$transaction.mockImplementation((fn: (tx: MockedPrisma) => unknown) => fn(db));
    db.stockCheck.findUnique.mockResolvedValue({ id: 'check-uuid-1', status: 'PENDING' });
    db.stockCheck.updateMany.mockResolvedValue({ count: 1 });
    db.stockCheck.update.mockImplementation(({ data }) => ({ id: 'check-uuid-1', ...data }));
    db.inventoryItem.findMany.mockResolvedValue(ITEMS);
    db.stockAlert.createMany.mockResolvedValue({ count: 2 });
  });

  it('evaluates inventory items, creates alerts for low-stock only, and marks check completed', async () => {
    const result = await processStockCheckJob(job(), { simulateFailure: false });

    expect(db.stockCheck.updateMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { id: 'check-uuid-1', status: { not: 'COMPLETED' } },
        data: expect.objectContaining({ status: 'PROCESSING' }),
      }),
    );
    expect(db.stockAlert.createMany).toHaveBeenCalledTimes(1);
    const { data, skipDuplicates } = db.stockAlert.createMany.mock.calls[0][0];
    expect(skipDuplicates).toBe(true);
    expect(data.map((a: { inventoryItemId: string }) => a.inventoryItemId)).toEqual(['item-1', 'item-3']);
    expect(db.stockCheck.update).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { id: 'check-uuid-1' },
        data: expect.objectContaining({ status: 'COMPLETED', totalChecked: 3, lowStockCount: 2 }),
      }),
    );
    expect(result.status).toBe('COMPLETED');
    expect(result.totalChecked).toBe(3);
    expect(result.lowStockCount).toBe(2);
  });

  it('writes alerts and the COMPLETED transition in one transaction', async () => {
    await processStockCheckJob(job(), { simulateFailure: false });
    expect(db.$transaction).toHaveBeenCalledTimes(1);
  });

  it('retries are idempotent: alerts use ON CONFLICT DO NOTHING on (stockCheckId, inventoryItemId)', async () => {
    db.stockCheck.findUnique.mockResolvedValue({ id: 'check-uuid-1', status: 'PROCESSING' });
    await processStockCheckJob(job({ attemptsMade: 1, attempts: 3 }), { simulateFailure: false });
    await processStockCheckJob(job({ attemptsMade: 2, attempts: 3 }), { simulateFailure: false });
    for (const [args] of db.stockAlert.createMany.mock.calls) {
      expect(args.skipDuplicates).toBe(true);
      for (const alert of args.data) expect(alert.stockCheckId).toBe('check-uuid-1');
    }
  });

  it('ignores duplicate delivery of an already COMPLETED check without recomputing', async () => {
    const completed = { id: 'check-uuid-1', status: 'COMPLETED', totalChecked: 3, lowStockCount: 2 };
    db.stockCheck.findUnique.mockResolvedValue(completed);

    await expect(processStockCheckJob(job(), { simulateFailure: false })).resolves.toBe(completed);
    expect(db.stockCheck.updateMany).not.toHaveBeenCalled();
    expect(db.$transaction).not.toHaveBeenCalled();
  });

  it('skips when a concurrent delivery completes the check between read and claim', async () => {
    db.stockCheck.updateMany.mockResolvedValueOnce({ count: 0 });
    db.stockCheck.findUnique
      .mockResolvedValueOnce({ id: 'check-uuid-1', status: 'PROCESSING' })
      .mockResolvedValueOnce({ id: 'check-uuid-1', status: 'COMPLETED' });

    const result = await processStockCheckJob(job(), { simulateFailure: false });
    expect(result.status).toBe('COMPLETED');
    expect(db.$transaction).not.toHaveBeenCalled();
  });

  it('handles simulated failure correctly: marks check FAILED with safe error message (final attempt)', async () => {
    await expect(processStockCheckJob(job(), { simulateFailure: true })).rejects.toThrow(
      'Simulated worker processing failure for demonstration purposes',
    );
    expect(db.stockCheck.updateMany).toHaveBeenLastCalledWith({
      where: { id: 'check-uuid-1', status: { not: 'COMPLETED' } },
      data: expect.objectContaining({
        status: 'FAILED',
        error: 'Simulated worker processing failure for demonstration purposes',
      }),
    });
  });

  it('keeps the check PROCESSING (not FAILED) when BullMQ will retry', async () => {
    await expect(
      processStockCheckJob(job({ attemptsMade: 0, attempts: 3 }), { simulateFailure: true }),
    ).rejects.toThrow();
    const last = db.stockCheck.updateMany.mock.calls.at(-1)[0];
    expect(last.data.status).toBe('PROCESSING');
    expect(last.data.error).toMatch(/^Attempt 1\/3 failed, retrying: /);
  });

  it('marks FAILED on the last configured attempt', async () => {
    await expect(
      processStockCheckJob(job({ attemptsMade: 2, attempts: 3 }), { simulateFailure: true }),
    ).rejects.toThrow();
    expect(db.stockCheck.updateMany.mock.calls.at(-1)[0].data.status).toBe('FAILED');
  });

  it('throws when the stock check record does not exist', async () => {
    db.stockCheck.findUnique.mockResolvedValue(null);
    await expect(processStockCheckJob(job(), { simulateFailure: false })).rejects.toThrow(/not found/);
  });
});

describe('isFinalAttempt', () => {
  it('derives finality from attemptsMade and opts.attempts', () => {
    expect(isFinalAttempt({ attemptsMade: 0, opts: {} } as Job)).toBe(true);
    expect(isFinalAttempt({ attemptsMade: 0, opts: { attempts: 3 } } as Job)).toBe(false);
    expect(isFinalAttempt({ attemptsMade: 2, opts: { attempts: 3 } } as Job)).toBe(true);
  });
});
