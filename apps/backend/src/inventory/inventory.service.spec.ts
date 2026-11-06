import { Test, TestingModule } from '@nestjs/testing';
import { InventoryService, computeInventoryStatus } from './inventory.service';
import { PrismaService } from '../prisma/prisma.service';
import { ConflictException, NotFoundException, BadRequestException } from '@nestjs/common';

describe('InventoryService & Low-Stock Rules', () => {
  let service: InventoryService;
  let prisma: {
    inventoryItem: {
      findMany: jest.Mock;
      findUnique: jest.Mock;
      create: jest.Mock;
      update: jest.Mock;
    };
  };

  beforeEach(async () => {
    prisma = {
      inventoryItem: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        InventoryService,
        { provide: PrismaService, useValue: prisma },
      ],
    }).compile();

    service = module.get<InventoryService>(InventoryService);
  });

  describe('computeInventoryStatus rule (quantity <= minQuantity)', () => {
    it('returns LOW_STOCK when quantity is less than minQuantity', () => {
      expect(computeInventoryStatus(3, 10)).toBe('LOW_STOCK');
      expect(computeInventoryStatus(0, 5)).toBe('LOW_STOCK');
    });

    it('returns LOW_STOCK when quantity equals minQuantity', () => {
      expect(computeInventoryStatus(10, 10)).toBe('LOW_STOCK');
      expect(computeInventoryStatus(0, 0)).toBe('LOW_STOCK');
    });

    it('returns HEALTHY when quantity is strictly greater than minQuantity', () => {
      expect(computeInventoryStatus(11, 10)).toBe('HEALTHY');
      expect(computeInventoryStatus(25, 10)).toBe('HEALTHY');
      expect(computeInventoryStatus(1, 0)).toBe('HEALTHY');
    });
  });

  describe('Inventory CRUD & Validation', () => {
    it('creates inventory item and returns computed status', async () => {
      const dto = {
        name: 'Wireless Mouse',
        sku: 'MOUSE-001',
        category: 'Accessories',
        quantity: 3,
        minQuantity: 10,
      };

      prisma.inventoryItem.findUnique.mockResolvedValue(null);
      prisma.inventoryItem.create.mockResolvedValue({
        id: 'uuid-1',
        ...dto,
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const result = await service.create(dto);
      expect(result.id).toBe('uuid-1');
      expect(result.status).toBe('LOW_STOCK');
    });

    it('throws ConflictException (409) on duplicate SKU', async () => {
      const dto = {
        name: 'Wireless Mouse',
        sku: 'MOUSE-001',
        category: 'Accessories',
        quantity: 3,
        minQuantity: 10,
      };

      prisma.inventoryItem.findUnique.mockResolvedValue({ id: 'existing-id', sku: 'MOUSE-001' });

      await expect(service.create(dto)).rejects.toThrow(ConflictException);
    });

    it('throws NotFoundException (404) for non-existent item', async () => {
      prisma.inventoryItem.findUnique.mockResolvedValue(null);
      await expect(service.findOne('non-existent')).rejects.toThrow(NotFoundException);
    });

    it('throws BadRequestException (400) on empty update body', async () => {
      await expect(service.update('uuid-1', {} as any)).rejects.toThrow(BadRequestException);
    });

    it('updates item and recomputes status', async () => {
      prisma.inventoryItem.findUnique.mockResolvedValue({
        id: 'uuid-1',
        name: 'Mouse',
        sku: 'MOUSE-001',
        category: 'Accessories',
        quantity: 3,
        minQuantity: 10,
      });

      prisma.inventoryItem.update.mockResolvedValue({
        id: 'uuid-1',
        name: 'Mouse',
        sku: 'MOUSE-001',
        category: 'Accessories',
        quantity: 15,
        minQuantity: 10,
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const updated = await service.update('uuid-1', { quantity: 15 });
      expect(updated.status).toBe('HEALTHY');
    });
  });
});
