import { Injectable, OnModuleInit, OnModuleDestroy, Logger } from '@nestjs/common';
import { PrismaClient } from '@stockwatch/database';

@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(PrismaService.name);

  async onModuleInit() {
    try {
      await this.$connect();
      this.logger.log('Connected to PostgreSQL database via Prisma');

      // Ensure types and tables exist individually
      await this.$executeRawUnsafe(`
        DO $$ BEGIN
          CREATE TYPE "CheckStatus" AS ENUM ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED');
        EXCEPTION
          WHEN duplicate_object THEN null;
        END $$;
      `);

      await this.$executeRawUnsafe(`
        CREATE TABLE IF NOT EXISTS "inventory_items" (
          "id" TEXT NOT NULL PRIMARY KEY,
          "name" TEXT NOT NULL,
          "sku" TEXT NOT NULL UNIQUE,
          "category" TEXT NOT NULL,
          "quantity" INTEGER NOT NULL,
          "minQuantity" INTEGER NOT NULL,
          "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
          "updatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
      `);

      await this.$executeRawUnsafe(`
        CREATE TABLE IF NOT EXISTS "stock_checks" (
          "id" TEXT NOT NULL PRIMARY KEY,
          "jobId" TEXT NOT NULL UNIQUE,
          "status" "CheckStatus" NOT NULL DEFAULT 'PENDING',
          "totalChecked" INTEGER NOT NULL DEFAULT 0,
          "lowStockCount" INTEGER NOT NULL DEFAULT 0,
          "error" TEXT,
          "startedAt" TIMESTAMP(3),
          "completedAt" TIMESTAMP(3),
          "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
      `);

      await this.$executeRawUnsafe(`
        CREATE TABLE IF NOT EXISTS "stock_alerts" (
          "id" TEXT NOT NULL PRIMARY KEY,
          "inventoryItemId" TEXT NOT NULL REFERENCES "inventory_items"("id") ON DELETE CASCADE ON UPDATE CASCADE,
          "stockCheckId" TEXT NOT NULL REFERENCES "stock_checks"("id") ON DELETE CASCADE ON UPDATE CASCADE,
          "quantity" INTEGER NOT NULL,
          "minQuantity" INTEGER NOT NULL,
          "message" TEXT NOT NULL,
          "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
          CONSTRAINT "stock_alerts_stockCheckId_inventoryItemId_key" UNIQUE ("stockCheckId", "inventoryItemId")
        );
      `);

      this.logger.log('Database schema verified and active');
    } catch (err) {
      this.logger.warn(`Database connection check: ${(err as Error).message}`);
    }
  }

  async onModuleDestroy() {
    await this.$disconnect();
    this.logger.log('Disconnected from PostgreSQL database');
  }

  async isHealthy(): Promise<boolean> {
    try {
      await this.$queryRaw`SELECT 1`;
      return true;
    } catch {
      return false;
    }
  }
}
