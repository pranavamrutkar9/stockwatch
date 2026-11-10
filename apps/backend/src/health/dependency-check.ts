/**
 * Helpers for dependency health probes.
 *
 * Health checks must never hang (a hung probe makes Docker, deploy scripts and
 * DNS health checks wait indefinitely) and must never leak credentials into
 * logs or HTTP responses.
 */

export const DEPENDENCY_CHECK_TIMEOUT_MS = 3000;

/** Rejects if `promise` does not settle within `timeoutMs`. */
export function withTimeout<T>(promise: Promise<T>, timeoutMs: number, operation: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${operation} timed out after ${timeoutMs}ms`)), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

const CONNECTION_STRING_PATTERN = /\b(postgres(?:ql)?|rediss?):\/\/[^\s'"`]+/gi;
const PASSWORD_PARAM_PATTERN = /(password=)[^&\s'"`]+/gi;

/**
 * Produces a short, single-line, credential-free description of an error,
 * suitable for server-side logs. Includes the Prisma/driver error code when
 * present (e.g. P1000 = authentication failed, P1001 = server unreachable).
 */
export function describeDependencyError(error: unknown): string {
  const err = error as { code?: unknown; errorCode?: unknown; message?: unknown; name?: unknown } | null | undefined;
  // PrismaClientKnownRequestError uses `code`; PrismaClientInitializationError uses `errorCode`.
  const code = [err?.code, err?.errorCode].find((value): value is string => typeof value === 'string');
  const name = typeof err?.name === 'string' ? err.name : 'Error';
  const rawMessage = typeof err?.message === 'string' ? err.message : String(error);

  // Prisma messages are multi-line and start with an "Invalid `...` invocation" preamble;
  // the last meaningful line carries the actual cause.
  const lines = rawMessage
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !/^Invalid `.*` invocation:?$/.test(line));
  const cause = lines.find((line) => !/^Please make sure/i.test(line)) ?? lines[0] ?? 'unknown error';

  const sanitized = cause
    .replace(CONNECTION_STRING_PATTERN, '$1://<redacted>')
    .replace(PASSWORD_PARAM_PATTERN, '$1<redacted>')
    .slice(0, 300);

  return code ? `${name} [${code}]: ${sanitized}` : `${name}: ${sanitized}`;
}

/**
 * Tracks a dependency's health state so failures are logged on transition and
 * then at most once per `repeatIntervalMs`, instead of once per health probe
 * (Docker probes every 10s).
 */
export class DependencyHealthLog {
  private healthy: boolean | undefined;
  private lastFailureLogAt = 0;

  constructor(
    private readonly name: string,
    private readonly logger: { warn(message: string): void; log(message: string): void },
    private readonly repeatIntervalMs = 60_000,
    private readonly now: () => number = Date.now,
  ) {}

  success(): void {
    if (this.healthy === false) {
      this.logger.log(`${this.name} health check recovered`);
    }
    this.healthy = true;
  }

  failure(error: unknown): void {
    const time = this.now();
    const transitioned = this.healthy !== false;
    if (transitioned || time - this.lastFailureLogAt >= this.repeatIntervalMs) {
      this.logger.warn(`${this.name} health check failed: ${describeDependencyError(error)}`);
      this.lastFailureLogAt = time;
    }
    this.healthy = false;
  }
}
