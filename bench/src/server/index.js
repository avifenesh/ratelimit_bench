/**
 * Benchmark Server for Rate Limiter
 *
 * Features:
 * - Supports multiple rate limiter implementations (Redis/Valkey)
 * - Tests both light and heavy request scenarios
 * - Supports both worker threads and cluster mode for scaling
 * - Provides detailed metrics for comparing rate limiter implementations
 */

const fastify = require('fastify');
const { isMainThread } = require('worker_threads');
const config = require('./config');
const { createClient, closeClient } = require('./lib/clientFactory');
const { createRateLimiter, closeRateLimiter } = require('./lib/rateLimiterFactory');
const createRateLimitMiddleware = require('./middleware/rateLimiter');
const registerRoutes = require('./routes');
const workerManager = require('./lib/workerManager');
const { setupCluster } = require('./utils/cluster');

// Only execute server code if this is the main thread
if (isMainThread) {
  // Function to start a server instance
  const startServer = async () => {
    console.log(`Starting server in ${config.mode} mode`);
    console.log(`Rate limit: ${config.rateLimit} requests per ${config.duration} seconds`);

    // Initialize client and rate limiter
    const client = await createClient();
    const rateLimiter = createRateLimiter(client);

    // Initialize metrics tracking
    const metrics = {
      totalRequests: 0,
      successRequests: 0,
      rejectedRequests: 0,
      lightRequests: 0,
      heavyRequests: 0,
      errors: 0,
      avgResponseTime: 0,
      responseTimes: [],
      startTime: Date.now()
    };

    // Initialize worker threads (if not in cluster mode)
    if (!config.useCluster) {
      await workerManager.initialize({
        mode: config.mode,
        redisHost: config.redisHost,
        redisPort: config.redisPort,
        valkeyHost: config.valkeyHost,
        valkeyPort: config.valkeyPort
      });
    }

    // Set up metrics collection from workers
    workerManager.setMessageHandler((message, worker) => {
      if (message.type === 'metrics') {
        // Aggregate metrics from workers
        metrics.totalRequests += message.data.requests || 0;
        metrics.successRequests += message.data.success || 0;
        metrics.rejectedRequests += message.data.rejected || 0;
        metrics.lightRequests += message.data.light || 0;
        metrics.heavyRequests += message.data.heavy || 0;
        metrics.errors += message.data.errors || 0;

        if (message.data.responseTime) {
          metrics.responseTimes.push(message.data.responseTime);
        }
      }
    });

    // Create Fastify app
    const app = fastify({
      logger: {
        level: 'info',
        transport: {
          target: 'pino-pretty',
          options: {
            translateTime: 'HH:MM:ss Z',
            ignore: 'pid,hostname'
          }
        }
      }
    });

    // Register JSON parser
    app.addContentTypeParser('application/json', { parseAs: 'string' }, function (req, body, done) {
      try {
        const json = JSON.parse(body);
        done(null, json);
      } catch (err) {
        err.statusCode = 400;
        done(err, undefined);
      }
    });

    // Add request logging
    app.addHook('onRequest', (request, reply, done) => {
      request.startTime = Date.now();
      done();
    });

    app.addHook('onResponse', (request, reply, done) => {
      const duration = Date.now() - request.startTime;
      app.log.info(`${request.method} ${request.url} ${reply.statusCode} ${duration}ms`);
      done();
    });

    // Create and register rate limiting middleware
    const rateLimitMiddleware = createRateLimitMiddleware(rateLimiter, metrics);

    // Register API routes
    registerRoutes(app, { rateLimitMiddleware, workerManager, metrics });

    // Start server
    try {
      await app.listen({ port: config.port, host: '0.0.0.0' });
      console.log(`Server running on port ${config.port} with ${config.workers} workers`);
      console.log(`Rate limiter: ${config.mode} (${config.rateLimit} requests per ${config.duration}s)`);
      console.log(`Process ID: ${process.pid}`);
    } catch (err) {
      app.log.error(err);
      process.exit(1);
    }

    // Graceful shutdown
    const shutdown = async () => {
      console.log('Shutting down server...');

      // Close server
      await app.close();
      console.log('Server closed');

      // Terminate all workers
      if (!config.useCluster) {
        workerManager.terminateAll();
      }

      // Close client and rate limiter
      await closeRateLimiter(rateLimiter);
      await closeClient(client);

      console.log('Shutdown complete');
      process.exit(0);
    };

    // Handle process termination signals
    process.on('SIGTERM', shutdown);
    process.on('SIGINT', shutdown);

    return app;
  };

  // Start server directly or in cluster mode based on configuration
  if (config.useCluster) {
    setupCluster(startServer);
  } else {
    startServer();
  }
}
