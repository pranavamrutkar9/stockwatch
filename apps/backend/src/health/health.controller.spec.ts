import { Test, TestingModule } from '@nestjs/testing';
import { HealthController } from './health.controller';
import { PrismaService } from '../prisma/prisma.service';
import { ServiceUnavailableException } from '@nestjs/common';

describe('HealthController', () => {
  let controller: HealthController;
  let prisma: { isHealthy: jest.Mock };

  beforeEach(async () => {
    prisma = { isHealthy: jest.fn() };

    const module: TestingModule = await Test.createTestingModule({
      controllers: [HealthController],
      providers: [{ provide: PrismaService, useValue: prisma }],
    }).compile();

    controller = module.get<HealthController>(HealthController);
  });

  it('returns ok status when database is healthy', async () => {
    prisma.isHealthy.mockResolvedValue(true);
    const result = await controller.check();
    expect(result.status).toBe('ok');
    expect(result.dependencies.database).toBe('connected');
  });

  it('throws ServiceUnavailableException (503) when database is unhealthy', async () => {
    prisma.isHealthy.mockResolvedValue(false);
    await expect(controller.check()).rejects.toThrow(ServiceUnavailableException);
  });
});
