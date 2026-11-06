import { Test, TestingModule } from '@nestjs/testing';
import { HealthController } from './health.controller';
import { PrismaService } from '../prisma/prisma.service';
import { QueueService } from '../queue/queue.service';
import { ServiceUnavailableException } from '@nestjs/common';

describe('HealthController', () => {
  let controller: HealthController;
  let prisma: { isHealthy: jest.Mock };
  let queueService: { isHealthy: jest.Mock };

  beforeEach(async () => {
    prisma = { isHealthy: jest.fn() };
    queueService = { isHealthy: jest.fn() };

    const module: TestingModule = await Test.createTestingModule({
      controllers: [HealthController],
      providers: [
        { provide: PrismaService, useValue: prisma },
        { provide: QueueService, useValue: queueService },
      ],
    }).compile();

    controller = module.get<HealthController>(HealthController);
  });

  it('returns ok status when database and redis are healthy', async () => {
    prisma.isHealthy.mockResolvedValue(true);
    queueService.isHealthy.mockResolvedValue(true);

    const result = await controller.check();
    expect(result.status).toBe('ok');
    expect(result.dependencies.database).toBe('connected');
    expect(result.dependencies.redis).toBe('connected');
  });

  it('throws ServiceUnavailableException (503) when database is unhealthy', async () => {
    prisma.isHealthy.mockResolvedValue(false);
    queueService.isHealthy.mockResolvedValue(true);

    await expect(controller.check()).rejects.toThrow(ServiceUnavailableException);
  });

  it('throws ServiceUnavailableException (503) when redis is unhealthy', async () => {
    prisma.isHealthy.mockResolvedValue(true);
    queueService.isHealthy.mockResolvedValue(false);

    await expect(controller.check()).rejects.toThrow(ServiceUnavailableException);
  });
});
