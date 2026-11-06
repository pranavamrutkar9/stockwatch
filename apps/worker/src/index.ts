import * as dotenv from 'dotenv';

dotenv.config();

console.log('[Worker] StockWatch Background Worker process initializing...');
console.log(`[Worker] Started at: ${new Date().toISOString()}`);
console.log(`[Worker] Process ID: ${process.pid}`);

let isShuttingDown = false;

// Heartbeat to keep the event loop alive until queue consumer is connected
const heartbeat = setInterval(() => {
  if (!isShuttingDown) {
    // Process is alive and ready
  }
}, 30000);

async function shutdown(signal: string) {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.log(`[Worker] Received ${signal}. Gracefully shutting down...`);

  clearInterval(heartbeat);

  console.log('[Worker] Graceful shutdown complete.');
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

console.log('[Worker] Worker initialized and ready for jobs.');

