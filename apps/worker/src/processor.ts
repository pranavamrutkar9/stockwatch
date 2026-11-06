import { prisma, StockCheck } from '@stockwatch/database';
import { Job } from 'bullmq';

export interface StockCheckJobData {
  stockCheckId: string;
}

export async function processStockCheckJob(
  job: Job<StockCheckJobData>,
  options?: { simulateFailure?: boolean },
): Promise<StockCheck> {
  const { stockCheckId } = job.data;
  console.log(`[Worker] Starting processing for Job #${job.id}, StockCheck ID: "${stockCheckId}"`);

  // Verify stock check record exists
  const stockCheck = await prisma.stockCheck.findUnique({
    where: { id: stockCheckId },
  });

  if (!stockCheck) {
    throw new Error(`StockCheck with ID "${stockCheckId}" not found in database.`);
  }

  // Update status to PROCESSING and set startedAt
  await prisma.stockCheck.update({
    where: { id: stockCheckId },
    data: {
      status: 'PROCESSING',
      startedAt: new Date(),
      error: null,
    },
  });

  // Check for failure simulation flag
  const shouldSimulateFailure =
    options?.simulateFailure ?? (process.env.WORKER_SIMULATE_FAILURE === 'true');

  if (shouldSimulateFailure) {
    const errorMsg = 'Simulated worker processing failure for demonstration purposes';
    console.warn(`[Worker] SIMULATING FAILURE for StockCheck ID: "${stockCheckId}"`);
    await prisma.stockCheck.update({
      where: { id: stockCheckId },
      data: {
        status: 'FAILED',
        error: errorMsg,
        completedAt: new Date(),
      },
    });
    throw new Error(errorMsg);
  }

  try {
    // Read all inventory items
    const inventoryItems = await prisma.inventoryItem.findMany();
    const totalChecked = inventoryItems.length;
    let lowStockCount = 0;

    for (const item of inventoryItems) {
      const isLowStock = item.quantity <= item.minQuantity;

      if (isLowStock) {
        lowStockCount++;

        // Idempotent upsert using unique compound index [stockCheckId, inventoryItemId]
        await prisma.stockAlert.upsert({
          where: {
            stockCheckId_inventoryItemId: {
              stockCheckId: stockCheck.id,
              inventoryItemId: item.id,
            },
          },
          create: {
            stockCheckId: stockCheck.id,
            inventoryItemId: item.id,
            quantity: item.quantity,
            minQuantity: item.minQuantity,
            message: `Low stock alert: "${item.name}" (SKU: ${item.sku}) has quantity ${item.quantity}, which is at or below minimum threshold ${item.minQuantity}`,
          },
          update: {
            quantity: item.quantity,
            minQuantity: item.minQuantity,
            message: `Low stock alert: "${item.name}" (SKU: ${item.sku}) has quantity ${item.quantity}, which is at or below minimum threshold ${item.minQuantity}`,
          },
        });
      }
    }

    // Mark COMPLETED with final totals
    const completedCheck = await prisma.stockCheck.update({
      where: { id: stockCheckId },
      data: {
        status: 'COMPLETED',
        totalChecked,
        lowStockCount,
        completedAt: new Date(),
        error: null,
      },
    });

    console.log(
      `[Worker] Completed Job #${job.id}: Checked ${totalChecked} items, found ${lowStockCount} low-stock items.`,
    );

    return completedCheck;
  } catch (err) {
    const errorMessage = (err as Error).message || 'Unknown processing error';
    console.error(`[Worker] Error processing Job #${job.id}: ${errorMessage}`);

    await prisma.stockCheck.update({
      where: { id: stockCheckId },
      data: {
        status: 'FAILED',
        error: errorMessage,
        completedAt: new Date(),
      },
    });

    throw err;
  }
}
