import { Test, TestingModule } from '@nestjs/testing';
import { StockChecksService } from './stock-checks.service';
import { PrismaService } from '../prisma/prisma.service';
import { QueueService } from '../queue/queue.service';
import { NotFoundException } from '@nestjs/common';

describe('StockChecksService', () => {
  let service: StockChecksService;
  let prisma: {
    stockCheck: {
      create: jest.Mock;
      update: jest.Mock;
      findMany: jest.Mock;
      findUnique: jest.Mock;
    };
  };
  let queueService: {
    addStockCheckJob: jest.Mock;
  };

  beforeEach(async () => {
    prisma = {
      stockCheck: {
        create: jest.fn(),
        update: jest.fn(),
        findMany: jest.fn(),
        findUnique: jest.fn(),
      },
    };
    queueService = {
      addStockCheckJob: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        StockChecksService,
        { provide: PrismaService, useValue: prisma },
        { provide: QueueService, useValue: queueService },
      ],
    }).compile();

    service = module.get<StockChecksService>(StockChecksService);
  });

  describe('enqueue', () => {
    it('persists a PENDING record whose jobId equals its ID, then enqueues with that job ID', async () => {
      prisma.stockCheck.create.mockResolvedValue({});
      queueService.addStockCheckJob.mockImplementation(async (id: string) => id);

      const result = await service.enqueue();

      const { data } = prisma.stockCheck.create.mock.calls[0][0];
      expect(data.status).toBe('PENDING');
      expect(data.jobId).toBe(data.id);
      expect(data.id).toMatch(/^[0-9a-f-]{36}$/);
      expect(queueService.addStockCheckJob).toHaveBeenCalledWith(data.id);
      expect(prisma.stockCheck.update).not.toHaveBeenCalled();
      expect(result).toEqual({
        success: true,
        id: data.id,
        jobId: data.id,
        status: 'PENDING',
        message: 'Stock check queued successfully',
      });
      // Persist before enqueue: the record must exist if the job is delivered immediately.
      expect(prisma.stockCheck.create.mock.invocationCallOrder[0]).toBeLessThan(
        queueService.addStockCheckJob.mock.invocationCallOrder[0],
      );
    });

    it('marks the record FAILED and rethrows when Redis is unavailable', async () => {
      prisma.stockCheck.create.mockResolvedValue({});
      queueService.addStockCheckJob.mockRejectedValue(new Error('Connection is closed.'));

      await expect(service.enqueue()).rejects.toThrow('Connection is closed.');
      expect(prisma.stockCheck.update).toHaveBeenCalledWith(
        expect.objectContaining({ data: expect.objectContaining({ status: 'FAILED' }) }),
      );
    });
  });

  describe('findOne', () => {
    it('throws NotFoundException when stock check does not exist', async () => {
      prisma.stockCheck.findUnique.mockResolvedValue(null);
      await expect(service.findOne('invalid-id')).rejects.toThrow(NotFoundException);
    });
  });
});
