import { Controller, Get, ServiceUnavailableException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { QueueService } from '../queue/queue.service';

@Controller('health')
export class HealthController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly queueService: QueueService,
  ) {}

  @Get()
  async check() {
    const isDbHealthy = await this.prisma.isHealthy();
    const isRedisHealthy = await this.queueService.isHealthy();

    const allHealthy = isDbHealthy && isRedisHealthy;

    const health = {
      status: allHealthy ? 'ok' : 'unhealthy',
      service: 'backend',
      timestamp: new Date().toISOString(),
      uptime: process.uptime(),
      dependencies: {
        database: isDbHealthy ? 'connected' : 'disconnected',
        redis: isRedisHealthy ? 'connected' : 'disconnected',
      },
    };

    if (!allHealthy) {
      throw new ServiceUnavailableException(health);
    }

    return health;
  }
}
