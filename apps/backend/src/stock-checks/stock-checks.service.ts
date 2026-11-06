import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
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
  constructor(private readonly prisma: PrismaService) {}

  async createCheck(jobId?: string): Promise<StockCheck> {
    const generatedJobId = jobId || `job-${Date.now()}-${randomUUID().slice(0, 8)}`;
    return this.prisma.stockCheck.create({
      data: {
        jobId: generatedJobId,
        status: 'PENDING',
      },
    });
  }

  async enqueue(): Promise<EnqueueStockCheckResult> {
    const check = await this.createCheck();
    return {
      success: true,
      id: check.id,
      jobId: check.jobId,
      status: check.status,
      message: 'Stock check queued successfully',
    };
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
