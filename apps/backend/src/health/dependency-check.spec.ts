import { DependencyHealthLog, describeDependencyError, withTimeout } from './dependency-check';
import { PrismaService } from '../prisma/prisma.service';
import { QueueService } from '../queue/queue.service';

const SECRET = 'sUp3r-s3cret-PW';

// Shape of the real error observed in production when RDS rejected rotated credentials.
function prismaAuthError(): Error & { code: string } {
  const err = new Error(
    [
      'Invalid `prisma.$queryRaw()` invocation:',
      '',
      '',
      'Authentication failed against database server, the provided database credentials for `stockwatch_admin` are not valid.',
      '',
      'Please make sure to provide valid database credentials for the database server at the configured address.',
    ].join('\n'),
  ) as Error & { code: string };
  err.name = 'PrismaClientKnownRequestError';
  err.code = 'P1000';
  return err;
}

const never = <T>() => new Promise<T>(() => undefined);

describe('describeDependencyError', () => {
  it('extracts the cause and Prisma error code from a multi-line Prisma error', () => {
    expect(describeDependencyError(prismaAuthError())).toBe(
      'PrismaClientKnownRequestError [P1000]: Authentication failed against database server, the provided database credentials for `stockwatch_admin` are not valid.',
    );
  });

  it('reads errorCode from Prisma initialization errors', () => {
    const err = Object.assign(new Error('Authentication failed against database server'), {
      name: 'PrismaClientInitializationError',
      errorCode: 'P1000',
    });
    expect(describeDependencyError(err)).toBe(
      'PrismaClientInitializationError [P1000]: Authentication failed against database server',
    );
  });

  it('redacts connection strings and password parameters', () => {
    const description = describeDependencyError(
      new Error(
        `connect failed for postgresql://admin:${SECRET}@db.example.com:5432/app?sslmode=require and redis://:${SECRET}@redis:6379 password=${SECRET}`,
      ),
    );
    expect(description).not.toContain(SECRET);
    expect(description).toContain('postgresql://<redacted>');
    expect(description).toContain('redis://<redacted>');
    expect(description).toContain('password=<redacted>');
  });

  it('handles non-Error values', () => {
    expect(describeDependencyError('boom')).toBe('Error: boom');
    expect(describeDependencyError(undefined)).toBe('Error: undefined');
  });
});

describe('withTimeout', () => {
  it('rejects when the operation does not settle in time', async () => {
    await expect(withTimeout(never(), 20, 'Slow op')).rejects.toThrow('Slow op timed out after 20ms');
  });

  it('resolves with the operation result when it settles in time', async () => {
    await expect(withTimeout(Promise.resolve('ok'), 1000, 'Fast op')).resolves.toBe('ok');
  });
});

describe('DependencyHealthLog', () => {
  it('logs on failure transition, throttles repeats and logs recovery', () => {
    const logger = { warn: jest.fn(), log: jest.fn() };
    let now = 0;
    const log = new DependencyHealthLog('Database', logger, 60_000, () => now);

    log.success();
    log.failure(prismaAuthError());
    now = 10_000;
    log.failure(prismaAuthError());
    expect(logger.warn).toHaveBeenCalledTimes(1);
    expect(logger.warn.mock.calls[0][0]).toContain('[P1000]');

    now = 70_000;
    log.failure(prismaAuthError());
    expect(logger.warn).toHaveBeenCalledTimes(2);

    log.success();
    expect(logger.log).toHaveBeenCalledWith('Database health check recovered');
  });
});

describe('PrismaService.isHealthy', () => {
  let service: PrismaService;
  let warn: jest.SpyInstance;

  beforeEach(() => {
    service = new PrismaService();
    warn = jest.spyOn((service as unknown as { logger: { warn: () => void } }).logger, 'warn').mockImplementation();
  });

  afterEach(() => jest.restoreAllMocks());

  it('returns true when SELECT 1 succeeds', async () => {
    jest.spyOn(service, '$queryRaw').mockResolvedValue([{ '?column?': 1 }] as never);
    await expect(service.isHealthy()).resolves.toBe(true);
    expect(warn).not.toHaveBeenCalled();
  });

  it('returns false and logs a sanitized cause when authentication fails', async () => {
    const err = prismaAuthError();
    err.message += `\npostgresql://stockwatch_admin:${SECRET}@db:5432/stockwatch`;
    jest.spyOn(service, '$queryRaw').mockRejectedValue(err as never);

    await expect(service.isHealthy()).resolves.toBe(false);
    expect(warn).toHaveBeenCalledTimes(1);
    const message = warn.mock.calls[0][0] as string;
    expect(message).toContain('[P1000]');
    expect(message).toContain('Authentication failed');
    expect(message).not.toContain(SECRET);
  });

  it('returns false instead of hanging when the database does not respond', async () => {
    jest.useFakeTimers();
    try {
      jest.spyOn(service, '$queryRaw').mockReturnValue(never() as never);
      const result = service.isHealthy();
      await jest.advanceTimersByTimeAsync(3000);
      await expect(result).resolves.toBe(false);
      expect(warn.mock.calls[0][0]).toContain('timed out');
    } finally {
      jest.useRealTimers();
    }
  });
});

describe('QueueService.isHealthy', () => {
  let service: QueueService;
  let warn: jest.SpyInstance;

  const withConnection = (ping: () => Promise<string>) => {
    (service as unknown as { redisConnection: { ping: () => Promise<string> } }).redisConnection = { ping };
  };

  beforeEach(() => {
    service = new QueueService();
    warn = jest.spyOn((service as unknown as { logger: { warn: () => void } }).logger, 'warn').mockImplementation();
  });

  afterEach(() => jest.restoreAllMocks());

  it('returns true on PONG', async () => {
    withConnection(() => Promise.resolve('PONG'));
    await expect(service.isHealthy()).resolves.toBe(true);
  });

  it('returns false when Redis rejects authentication', async () => {
    withConnection(() => Promise.reject(new Error('WRONGPASS invalid username-password pair or user is disabled.')));
    await expect(service.isHealthy()).resolves.toBe(false);
    expect(warn.mock.calls[0][0]).toContain('WRONGPASS');
  });

  it('returns false instead of hanging when Redis is unreachable', async () => {
    jest.useFakeTimers();
    try {
      withConnection(() => never());
      const result = service.isHealthy();
      await jest.advanceTimersByTimeAsync(3000);
      await expect(result).resolves.toBe(false);
    } finally {
      jest.useRealTimers();
    }
  });

  it('returns false when the connection is not initialized', async () => {
    await expect(service.isHealthy()).resolves.toBe(false);
  });
});
