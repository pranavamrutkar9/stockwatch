import { Module } from '@nestjs/common';
import { StockChecksController } from './stock-checks.controller';
import { StockChecksService } from './stock-checks.service';
import { StockCheckRecoveryService } from './stock-check-recovery.service';

@Module({
  controllers: [StockChecksController],
  providers: [StockChecksService, StockCheckRecoveryService],
  exports: [StockChecksService],
})
export class StockChecksModule {}
