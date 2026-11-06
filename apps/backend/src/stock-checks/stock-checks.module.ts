import { Module } from '@nestjs/common';
import { StockChecksController } from './stock-checks.controller';
import { StockChecksService } from './stock-checks.service';

@Module({
  controllers: [StockChecksController],
  providers: [StockChecksService],
  exports: [StockChecksService],
})
export class StockChecksModule {}
