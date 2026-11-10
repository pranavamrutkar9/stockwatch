import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { QueueService } from '../queue/queue.service';
import { StockCheck } from '@stockwatch/database';
import { randomUUID } from 'crypto';

export interface EnqueueStockCheckResult {
  success: boolean;
  id: string;
  jobId: string;
  status: string;
  message: string;
}

@Injectable()
export class StockChecksService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly queueService: QueueService,
  ) {}

  async enqueue(): Promise<EnqueueStockCheckResult> {
    // The record ID doubles as the BullMQ job ID (see QueueService.addStockCheckJob),
    // so the persisted jobId is known before enqueueing and never needs rewriting.
    const id = randomUUID();

    // 1. Persist the PENDING record first: PostgreSQL is the source of truth, and
    //    StockCheckRecoveryService re-enqueues PENDING records if Redis loses the job.
    await this.prisma.stockCheck.create({
      data: { id, jobId: id, status: 'PENDING' },
    });

    try {
      // 2. Enqueue (idempotent per job ID).
      const jobId = await this.queueService.addStockCheckJob(id);

      return {
        success: true,
        id,
        jobId,
        status: 'PENDING',
        message: 'Stock check queued successfully',
      };
    } catch (err) {
      // Queue unreachable: record a terminal failure so the client stops polling.
      await this.prisma.stockCheck.update({
        where: { id },
        data: {
          status: 'FAILED',
          error: `Failed to enqueue job: ${(err as Error).message}`,
          completedAt: new Date(),
        },
      });
      throw err;
    }
  }

  async findAll(): Promise<StockCheck[]> {
    return this.prisma.stockCheck.findMany({
      orderBy: { createdAt: 'desc' },
      include: {
        _count: {
          select: { alerts: true },
        },
      },
    });
  }

  async findOne(id: string): Promise<StockCheck> {
    const check = await this.prisma.stockCheck.findUnique({
      where: { id },
      include: {
        alerts: {
          include: {
            inventoryItem: true,
          },
        },
      },
    });
    if (!check) {
      throw new NotFoundException(`Stock check with ID "${id}" not found`);
    }
    return check;
  }
}
