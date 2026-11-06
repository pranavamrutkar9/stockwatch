import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';

@Injectable()
export class AlertsService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll() {
    return this.prisma.stockAlert.findMany({
      orderBy: { createdAt: 'desc' },
      include: {
        inventoryItem: true,
        stockCheck: true,
      },
    });
  }
}
