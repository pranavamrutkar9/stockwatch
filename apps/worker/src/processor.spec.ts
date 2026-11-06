import { processStockCheckJob } from './processor';
import { prisma } from '@stockwatch/database';
import { Job } from 'bullmq';

jest.mock('@stockwatch/database', () => {
  return {
    prisma: {
      stockCheck: {
        findUnique: jest.fn(),
        update: jest.fn(),
      },
      inventoryItem: {
        findMany: jest.fn(),
      },
      stockAlert: {
        upsert: jest.fn(),
      },
    },
  };
});

describe('Worker processStockCheckJob', () => {
  const mockJob = {
    id: 'job-101',
    data: { stockCheckId: 'check-uuid-1' },
  } as unknown as Job<{ stockCheckId: string }>;

  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('evaluates inventory items, creates alerts for low-stock only, and marks check completed', async () => {
    (prisma.stockCheck.findUnique as jest.Mock).mockResolvedValue({
      id: 'check-uuid-1',
      status: 'PENDING',
    });

    (prisma.stockCheck.update as jest.Mock).mockImplementation(({ data }) => ({
      id: 'check-uuid-1',
      ...data,
    }));

    (prisma.inventoryItem.findMany as jest.Mock).mockResolvedValue([
      { id: 'item-1', name: 'Mouse', sku: 'M01', quantity: 3, minQuantity: 10 }, // Low stock (3 <= 10)
      { id: 'item-2', name: 'Keyboard', sku: 'K01', quantity: 20, minQuantity: 5 }, // Healthy (20 > 5)
      { id: 'item-3', name: 'USB Hub', sku: 'U01', quantity: 4, minQuantity: 4 }, // Low stock (4 <= 4)
    ]);

    (prisma.stockAlert.upsert as jest.Mock).mockResolvedValue({});

    const result = await processStockCheckJob(mockJob, { simulateFailure: false });

    // Verify status transitions: PROCESSING -> COMPLETED
    expect(prisma.stockCheck.update).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { id: 'check-uuid-1' },
        data: expect.objectContaining({ status: 'PROCESSING' }),
      }),
    );

    expect(prisma.stockCheck.update).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { id: 'check-uuid-1' },
        data: expect.objectContaining({
          status: 'COMPLETED',
          totalChecked: 3,
          lowStockCount: 2,
        }),
      }),
    );

    // Verify that alerts were upserted only for low-stock items (Mouse & USB Hub)
    expect(prisma.stockAlert.upsert).toHaveBeenCalledTimes(2);
    expect(prisma.stockAlert.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        where: {
          stockCheckId_inventoryItemId: {
            stockCheckId: 'check-uuid-1',
            inventoryItemId: 'item-1',
          },
        },
      }),
    );
    expect(prisma.stockAlert.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        where: {
          stockCheckId_inventoryItemId: {
            stockCheckId: 'check-uuid-1',
            inventoryItemId: 'item-3',
          },
        },
      }),
    );

    expect(result.status).toBe('COMPLETED');
    expect(result.totalChecked).toBe(3);
    expect(result.lowStockCount).toBe(2);
  });

  it('guarantees idempotency on retries: upsert called with same keys without duplicate records', async () => {
    (prisma.stockCheck.findUnique as jest.Mock).mockResolvedValue({
      id: 'check-uuid-1',
      status: 'PROCESSING',
    });

    (prisma.stockCheck.update as jest.Mock).mockImplementation(({ data }) => ({
      id: 'check-uuid-1',
      ...data,
    }));

    (prisma.inventoryItem.findMany as jest.Mock).mockResolvedValue([
      { id: 'item-1', name: 'Mouse', sku: 'M01', quantity: 2, minQuantity: 5 },
    ]);

    // First execution
    await processStockCheckJob(mockJob, { simulateFailure: false });
    expect(prisma.stockAlert.upsert).toHaveBeenCalledTimes(1);

    // Retry execution
    await processStockCheckJob(mockJob, { simulateFailure: false });
    expect(prisma.stockAlert.upsert).toHaveBeenCalledTimes(2);

    // Both times used the idempotent unique constraint key
    expect(prisma.stockAlert.upsert).toHaveBeenLastCalledWith(
      expect.objectContaining({
        where: {
          stockCheckId_inventoryItemId: {
            stockCheckId: 'check-uuid-1',
            inventoryItemId: 'item-1',
          },
        },
      }),
    );
  });

  it('handles simulated failure correctly: marks check FAILED with safe error message', async () => {
    (prisma.stockCheck.findUnique as jest.Mock).mockResolvedValue({
      id: 'check-uuid-1',
      status: 'PENDING',
    });

    (prisma.stockCheck.update as jest.Mock).mockImplementation(({ data }) => ({
      id: 'check-uuid-1',
      ...data,
    }));

    await expect(processStockCheckJob(mockJob, { simulateFailure: true })).rejects.toThrow(
      'Simulated worker processing failure for demonstration purposes',
    );

    expect(prisma.stockCheck.update).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { id: 'check-uuid-1' },
        data: expect.objectContaining({
          status: 'FAILED',
          error: 'Simulated worker processing failure for demonstration purposes',
        }),
      }),
    );
  });
});
