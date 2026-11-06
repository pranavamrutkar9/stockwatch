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
    const tempJobId = `job-${Date.now()}-${randomUUID().slice(0, 8)}`;
    
    // 1. Create StockCheck record with PENDING status in PostgreSQL
    const check = await this.prisma.stockCheck.create({
      data: {
        jobId: tempJobId,
        status: 'PENDING',
      },
    });

    try {
      // 2. Add job to BullMQ queue
      const bullJobId = await this.queueService.addStockCheckJob(check.id);

      // 3. Update record with actual BullMQ jobId if different
      if (bullJobId && bullJobId !== tempJobId) {
        await this.prisma.stockCheck.update({
          where: { id: check.id },
          data: { jobId: bullJobId },
        });
      }

      return {
        success: true,
        id: check.id,
        jobId: bullJobId || tempJobId,
        status: 'PENDING',
        message: 'Stock check queued successfully',
      };
    } catch (err) {
      // If queue is unreachable, record failure or fallback
      await this.prisma.stockCheck.update({
        where: { id: check.id },
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
