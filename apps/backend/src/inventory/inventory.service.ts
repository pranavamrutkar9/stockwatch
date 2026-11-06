import {
  Injectable,
  NotFoundException,
  ConflictException,
  BadRequestException,
} from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { CreateInventoryDto } from './dto/create-inventory.dto';
import { UpdateInventoryDto } from './dto/update-inventory.dto';
import { InventoryItem } from '@stockwatch/database';

export interface InventoryItemWithStatus extends InventoryItem {
  status: 'LOW_STOCK' | 'HEALTHY';
}

export function computeInventoryStatus(quantity: number, minQuantity: number): 'LOW_STOCK' | 'HEALTHY' {
  return quantity <= minQuantity ? 'LOW_STOCK' : 'HEALTHY';
}

@Injectable()
export class InventoryService {
  constructor(private readonly prisma: PrismaService) {}

  private withStatus(item: InventoryItem): InventoryItemWithStatus {
    return {
      ...item,
      status: computeInventoryStatus(item.quantity, item.minQuantity),
    };
  }

  async findAll(): Promise<InventoryItemWithStatus[]> {
    const items = await this.prisma.inventoryItem.findMany({
      orderBy: { createdAt: 'desc' },
    });
    return items.map((item) => this.withStatus(item));
  }

  async findOne(id: string): Promise<InventoryItemWithStatus> {
    const item = await this.prisma.inventoryItem.findUnique({
      where: { id },
    });
    if (!item) {
      throw new NotFoundException(`Inventory item with ID "${id}" not found`);
    }
    return this.withStatus(item);
  }

  async create(dto: CreateInventoryDto): Promise<InventoryItemWithStatus> {
    const existing = await this.prisma.inventoryItem.findUnique({
      where: { sku: dto.sku },
    });
    if (existing) {
      throw new ConflictException(`Inventory item with SKU "${dto.sku}" already exists`);
    }

    const created = await this.prisma.inventoryItem.create({
      data: {
        name: dto.name,
        sku: dto.sku,
        category: dto.category,
        quantity: dto.quantity,
        minQuantity: dto.minQuantity,
      },
    });

    return this.withStatus(created);
  }

  async update(id: string, dto: UpdateInventoryDto): Promise<InventoryItemWithStatus> {
    if (!dto || Object.keys(dto).length === 0) {
      throw new BadRequestException('Update payload must not be empty');
    }

    const existing = await this.prisma.inventoryItem.findUnique({
      where: { id },
    });
    if (!existing) {
      throw new NotFoundException(`Inventory item with ID "${id}" not found`);
    }

    if (dto.sku && dto.sku !== existing.sku) {
      const skuConflict = await this.prisma.inventoryItem.findUnique({
        where: { sku: dto.sku },
      });
      if (skuConflict) {
        throw new ConflictException(`Inventory item with SKU "${dto.sku}" already exists`);
      }
    }

    const updated = await this.prisma.inventoryItem.update({
      where: { id },
      data: {
        ...(dto.name !== undefined && { name: dto.name }),
        ...(dto.sku !== undefined && { sku: dto.sku }),
        ...(dto.category !== undefined && { category: dto.category }),
        ...(dto.quantity !== undefined && { quantity: dto.quantity }),
        ...(dto.minQuantity !== undefined && { minQuantity: dto.minQuantity }),
      },
    });

    return this.withStatus(updated);
  }
}
