import { Controller, Get, Post, Patch, Body, Param } from '@nestjs/common';
import { InventoryService, InventoryItemWithStatus } from './inventory.service';
import { CreateInventoryDto } from './dto/create-inventory.dto';
import { UpdateInventoryDto } from './dto/update-inventory.dto';

@Controller('inventory')
export class InventoryController {
  constructor(private readonly inventoryService: InventoryService) {}

  @Get()
  async findAll(): Promise<InventoryItemWithStatus[]> {
    return this.inventoryService.findAll();
  }

  @Get(':id')
  async findOne(@Param('id') id: string): Promise<InventoryItemWithStatus> {
    return this.inventoryService.findOne(id);
  }

  @Post()
  async create(@Body() createDto: CreateInventoryDto): Promise<InventoryItemWithStatus> {
    return this.inventoryService.create(createDto);
  }

  @Patch(':id')
  async update(
    @Param('id') id: string,
    @Body() updateDto: UpdateInventoryDto,
  ): Promise<InventoryItemWithStatus> {
    return this.inventoryService.update(id, updateDto);
  }
}
