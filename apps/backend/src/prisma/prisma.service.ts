import { Injectable, OnModuleInit, OnModuleDestroy, Logger } from '@nestjs/common';
import { PrismaClient } from '@stockwatch/database';
import {
  DEPENDENCY_CHECK_TIMEOUT_MS,
  DependencyHealthLog,
  describeDependencyError,
  withTimeout,
} from '../health/dependency-check';

@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(PrismaService.name);
  private readonly healthLog = new DependencyHealthLog('Database', this.logger);

  async onModuleInit() {
    try {
      await this.$connect();
      this.logger.log('Connected to PostgreSQL database via Prisma');

      // Production schema is owned by Prisma migrations (deploy.sh runs `migrate deploy`
      // with migration credentials). The runtime role is DML-only, so it must not run DDL.
      // The local docker-compose.yml sets DB_BOOTSTRAP_SCHEMA=true because it has no
      // migration step.
      if (process.env.DB_BOOTSTRAP_SCHEMA !== 'true') {
        await this.$queryRaw`SELECT 1 FROM "stock_checks" LIMIT 1`;
        this.logger.log('Database reachable; schema managed by Prisma migrations');
        return;
      }

      // Development-only: ensure types and tables exist individually
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
      this.logger.warn(`Database connection check failed: ${describeDependencyError(err)}`);
    }
  }

  async onModuleDestroy() {
    await this.$disconnect();
    this.logger.log('Disconnected from PostgreSQL database');
  }

  /**
   * Readiness probe: opens/uses a pooled connection and runs `SELECT 1`.
   * Failures (e.g. P1000 authentication failed, P1001 unreachable, TLS errors)
   * are logged server-side in sanitized form; callers only receive a boolean.
   */
  async isHealthy(): Promise<boolean> {
    try {
      await withTimeout(this.$queryRaw`SELECT 1`, DEPENDENCY_CHECK_TIMEOUT_MS, 'Database SELECT 1');
      this.healthLog.success();
      return true;
    } catch (err) {
      this.healthLog.failure(err);
      return false;
    }
  }
}
