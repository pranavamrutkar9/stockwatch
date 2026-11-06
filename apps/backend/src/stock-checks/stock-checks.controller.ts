import { Controller, Get, Post, Param } from '@nestjs/common';
import { StockChecksService, EnqueueStockCheckResult } from './stock-checks.service';
import { StockCheck } from '@stockwatch/database';

@Controller('stock-checks')
export class StockChecksController {
  constructor(private readonly stockChecksService: StockChecksService) {}

  @Post()
  async enqueue(): Promise<EnqueueStockCheckResult> {
    return this.stockChecksService.enqueue();
  }

  @Get()
  async findAll(): Promise<StockCheck[]> {
    return this.stockChecksService.findAll();
  }

  @Get(':id')
  async findOne(@Param('id') id: string): Promise<StockCheck> {
    return this.stockChecksService.findOne(id);
  }
}
