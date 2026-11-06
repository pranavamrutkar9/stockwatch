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
    it('creates a PENDING database record and enqueues BullMQ job promptly', async () => {
      prisma.stockCheck.create.mockResolvedValue({
        id: 'check-uuid-1',
        jobId: 'temp-job-id',
        status: 'PENDING',
      });
      queueService.addStockCheckJob.mockResolvedValue('bull-job-123');
      prisma.stockCheck.update.mockResolvedValue({
        id: 'check-uuid-1',
        jobId: 'bull-job-123',
        status: 'PENDING',
      });

      const result = await service.enqueue();

      expect(prisma.stockCheck.create).toHaveBeenCalled();
      expect(queueService.addStockCheckJob).toHaveBeenCalledWith('check-uuid-1');
      expect(result).toEqual({
        success: true,
        id: 'check-uuid-1',
        jobId: 'bull-job-123',
        status: 'PENDING',
        message: 'Stock check queued successfully',
      });
    });
  });

  describe('findOne', () => {
    it('throws NotFoundException when stock check does not exist', async () => {
      prisma.stockCheck.findUnique.mockResolvedValue(null);
      await expect(service.findOne('invalid-id')).rejects.toThrow(NotFoundException);
    });
  });
});
