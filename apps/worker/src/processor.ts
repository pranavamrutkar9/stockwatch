import { prisma, StockCheck } from '@stockwatch/database';
import { Job } from 'bullmq';

export interface StockCheckJobData {
  stockCheckId: string;
}

const MAX_ERROR_LENGTH = 500;

/** True when this execution is the job's last permitted attempt. */
export function isFinalAttempt(job: Pick<Job, 'attemptsMade' | 'opts'>): boolean {
  const attempts = job.opts?.attempts ?? 1;
  // BullMQ: attemptsMade = number of previously failed attempts while the processor runs.
  return (job.attemptsMade ?? 0) + 1 >= attempts;
}

/**
 * Processes one stock check. Safe under BullMQ at-least-once delivery:
 *
 * - Re-delivery after completion (worker crash after commit, stalled-job
 *   re-delivery, PostgreSQL-backed recovery) is a no-op: a COMPLETED check is
 *   never recomputed, so its snapshot is stable.
 * - Concurrent duplicate execution is safe: alerts are inserted with
 *   ON CONFLICT DO NOTHING on (stockCheckId, inventoryItemId), and alerts plus
 *   the COMPLETED transition commit atomically.
 * - Only the final failed attempt marks the check FAILED; earlier failures keep
 *   it PROCESSING with the error recorded, so clients polling for a terminal
 *   status do not stop on a failure that BullMQ is about to retry.
 */
export async function processStockCheckJob(
  job: Job<StockCheckJobData>,
  options?: { simulateFailure?: boolean },
): Promise<StockCheck> {
  const { stockCheckId } = job.data;
  console.log(`[Worker] Starting processing for Job #${job.id}, StockCheck ID: "${stockCheckId}"`);

  const stockCheck = await prisma.stockCheck.findUnique({ where: { id: stockCheckId } });
  if (!stockCheck) {
    throw new Error(`StockCheck with ID "${stockCheckId}" not found in database.`);
  }

  if (stockCheck.status === 'COMPLETED') {
    console.log(`[Worker] StockCheck "${stockCheckId}" already COMPLETED; duplicate delivery ignored.`);
    return stockCheck;
  }

  // Claim: move to PROCESSING unless another delivery completed it meanwhile.
  const claimed = await prisma.stockCheck.updateMany({
    where: { id: stockCheckId, status: { not: 'COMPLETED' } },
    data: { status: 'PROCESSING', startedAt: new Date(), error: null },
  });
  if (claimed.count === 0) {
    console.log(`[Worker] StockCheck "${stockCheckId}" completed by another delivery; skipping.`);
    return (await prisma.stockCheck.findUnique({ where: { id: stockCheckId } })) as StockCheck;
  }

  try {
    const shouldSimulateFailure = options?.simulateFailure ?? process.env.WORKER_SIMULATE_FAILURE === 'true';
    if (shouldSimulateFailure) {
      console.warn(`[Worker] SIMULATING FAILURE for StockCheck ID: "${stockCheckId}"`);
      throw new Error('Simulated worker processing failure for demonstration purposes');
    }

    const completedCheck = await prisma.$transaction(async (tx) => {
      const inventoryItems = await tx.inventoryItem.findMany();
      const lowStockItems = inventoryItems.filter((item) => item.quantity <= item.minQuantity);

      if (lowStockItems.length > 0) {
        await tx.stockAlert.createMany({
          data: lowStockItems.map((item) => ({
            stockCheckId,
            inventoryItemId: item.id,
            quantity: item.quantity,
            minQuantity: item.minQuantity,
            message: `Low stock alert: "${item.name}" (SKU: ${item.sku}) has quantity ${item.quantity}, which is at or below minimum threshold ${item.minQuantity}`,
          })),
          skipDuplicates: true,
        });
      }

      return tx.stockCheck.update({
        where: { id: stockCheckId },
        data: {
          status: 'COMPLETED',
          totalChecked: inventoryItems.length,
          lowStockCount: lowStockItems.length,
          completedAt: new Date(),
          error: null,
        },
      });
    });

    console.log(
      `[Worker] Completed Job #${job.id}: Checked ${completedCheck.totalChecked} items, found ${completedCheck.lowStockCount} low-stock items.`,
    );
    return completedCheck;
  } catch (err) {
    const errorMessage = ((err as Error).message || 'Unknown processing error').slice(0, MAX_ERROR_LENGTH);
    const final = isFinalAttempt(job);
    const attempt = (job.attemptsMade ?? 0) + 1;
    const attempts = job.opts?.attempts ?? 1;
    console.error(
      `[Worker] Error processing Job #${job.id} (attempt ${attempt}/${attempts}${final ? ', final' : ', will retry'}): ${errorMessage}`,
    );

    // Never overwrite a COMPLETED result written by a concurrent delivery.
    await prisma.stockCheck.updateMany({
      where: { id: stockCheckId, status: { not: 'COMPLETED' } },
      data: final
        ? { status: 'FAILED', error: errorMessage, completedAt: new Date() }
        : { status: 'PROCESSING', error: `Attempt ${attempt}/${attempts} failed, retrying: ${errorMessage}` },
    });

    throw err;
  }
}
