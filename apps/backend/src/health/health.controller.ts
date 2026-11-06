import { Controller, Get, ServiceUnavailableException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';

@Controller('health')
export class HealthController {
  constructor(private readonly prisma: PrismaService) {}

  @Get()
  async check() {
    const isDbHealthy = await this.prisma.isHealthy();

    const health = {
      status: isDbHealthy ? 'ok' : 'unhealthy',
      service: 'backend',
      timestamp: new Date().toISOString(),
      uptime: process.uptime(),
      dependencies: {
        database: isDbHealthy ? 'connected' : 'disconnected',
      },
    };

    if (!isDbHealthy) {
      throw new ServiceUnavailableException(health);
    }

    return health;
  }
}
