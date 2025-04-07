/**
 * API Routes
 * Defines all API endpoints for the benchmark server
 */

const crypto = require('crypto');

/**
 * Registers API routes with the Fastify app
 * @param {Object} app - Fastify app instance
 * @param {Object} options - Options including middleware and workers
 */
function registerRoutes(app, { rateLimitMiddleware, workerManager, metrics }) {
  // Light request - minimal processing
  app.get('/api/light', async (request, reply) => {
    await rateLimitMiddleware(request, reply);

    // If rate limited, the middleware will have sent a response already
    if (reply.sent) return;

    const startTime = Date.now();

    // Forward to worker for processing
    const worker = workerManager.getNextWorker();
    worker.postMessage({
      type: 'request',
      requestType: 'light',
      userId: request.headers['user-id'] || request.ip
    });

    metrics.lightRequests++;
    metrics.successRequests++;

    // Simulate minimal processing time
    await new Promise(resolve => setTimeout(resolve, 5));

    const responseTime = Date.now() - startTime;
    metrics.responseTimes.push(responseTime);

    return reply.send({
      success: true,
      message: 'Light request processed',
      processingTime: responseTime
    });
  });

  // Heavy request - more intensive processing
  app.get('/api/heavy', async (request, reply) => {
    await rateLimitMiddleware(request, reply);

    // If rate limited, the middleware will have sent a response already
    if (reply.sent) return;

    const startTime = Date.now();

    // Forward to worker for processing
    const worker = workerManager.getNextWorker();
    worker.postMessage({
      type: 'request',
      requestType: 'heavy',
      userId: request.headers['user-id'] || request.ip
    });

    metrics.heavyRequests++;
    metrics.successRequests++;

    // Simulate heavier processing with cryptographic operations
    try {
      const data = crypto.randomBytes(10000).toString('hex');
      const hash = crypto.pbkdf2Sync(data, 'salt', 100, 64, 'sha512').toString('hex');

      const responseTime = Date.now() - startTime;
      metrics.responseTimes.push(responseTime);

      return reply.send({
        success: true,
        message: 'Heavy request processed',
        processingTime: responseTime,
        hashLength: hash.length
      });
    } catch (err) {
      metrics.errors++;
      return reply.code(500).send({ error: 'Processing error' });
    }
  });

  // Health check endpoint
  app.get('/health', (request, reply) => {
    return reply.send({
      status: 'ok',
      uptime: process.uptime(),
      workers: workerManager.workers.length,
      mode: process.env.MODE || 'valkey-glide',
      processId: process.pid
    });
  });

  // Metrics endpoint
  app.get('/metrics', (request, reply) => {
    const totalTime = Date.now() - metrics.startTime;
    const avgResponseTime = metrics.responseTimes.length > 0
      ? metrics.responseTimes.reduce((a, b) => a + b, 0) / metrics.responseTimes.length
      : 0;

    // Sort response times for percentile calculations
    const sortedTimes = [...metrics.responseTimes].sort((a, b) => a - b);
    const p95Index = Math.floor(sortedTimes.length * 0.95);
    const p99Index = Math.floor(sortedTimes.length * 0.99);

    return reply.send({
      uptime: process.uptime(),
      processId: process.pid,
      totalRequests: metrics.totalRequests,
      successRequests: metrics.successRequests,
      rejectedRequests: metrics.rejectedRequests,
      errorRate: metrics.totalRequests > 0 ? (metrics.errors / metrics.totalRequests) * 100 : 0,
      rps: metrics.totalRequests / (totalTime / 1000),
      avgResponseTime,
      p95ResponseTime: sortedTimes[p95Index] || 0,
      p99ResponseTime: sortedTimes[p99Index] || 0,
      lightRequests: metrics.lightRequests,
      heavyRequests: metrics.heavyRequests,
      workerCount: workerManager.workers.length,
      mode: process.env.MODE || 'valkey-glide'
    });
  });
}

module.exports = registerRoutes;
