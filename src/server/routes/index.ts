import {
  FastifyPluginAsync,
  FastifyInstance,
  FastifyRequest,
  FastifyReply,
} from "fastify";
import { rateLimiter } from "../middleware/rateLimiter.js";
import client from "prom-client";

// Initialize Prometheus metrics
const register = new client.Registry();
client.collectDefaultMetrics({ register });

// Custom metrics for rate limiter
const rateLimitHits = new client.Counter({
  name: "ratelimit_hits_total",
  help: "Total number of rate limit hits",
  labelNames: ["mode"],
});

const rateLimitConsume = new client.Counter({
  name: "ratelimit_consume_total",
  help: "Total number of rate limit point consumptions",
  labelNames: ["mode"],
});

const requestDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route", "status_code"],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
});

register.registerMetric(rateLimitHits);
register.registerMetric(rateLimitConsume);
register.registerMetric(requestDuration);

const routes: FastifyPluginAsync = async (fastify: FastifyInstance) => {
  // Apply the rate limiter middleware to all routes except health check
  // Use a more specific path prefix to exclude health routes
  fastify.addHook(
    "onRequest",
    async (request: FastifyRequest, reply: FastifyReply) => {
      // Skip rate limiting for health check endpoints
      if (request.url === "/health") {
        return;
      }
      // Apply rate limiting for all other routes
      await rateLimiter(request, reply);
    }
  );

  // Define routes
  fastify.get("/", async (_request: FastifyRequest, _reply: FastifyReply) => {
    return "Hello, world!"; // In Fastify, you can simply return the value
  });

  // Health check endpoint for monitoring and benchmark scripts
  fastify.get(
    "/health",
    async (_request: FastifyRequest, _reply: FastifyReply) => {
      return { status: "ok" };
    }
  );

  // API endpoint for benchmarking - light workload
  fastify.get(
    "/api/light",
    async (_request: FastifyRequest, _reply: FastifyReply) => {
      return { success: true, timestamp: Date.now() };
    }
  );

  // API endpoint for benchmarking - heavy workload
  fastify.get(
    "/api/heavy",
    async (_request: FastifyRequest, _reply: FastifyReply) => {
      // Simulate some CPU-intensive work
      const result = Array.from({ length: 10000 }).reduce(
        (acc: number, _, i) => {
          return acc + Math.sqrt(i);
        },
        0
      );

      return {
        success: true,
        timestamp: Date.now(),
        result,
      };
    }
  );

  // Prometheus metrics endpoint
  fastify.get(
    "/metrics",
    async (_request: FastifyRequest, reply: FastifyReply) => {
      reply.header("Content-Type", register.contentType);
      return await register.metrics();
    }
  );
};

// Export the metrics for use in other parts of the application
export { rateLimitHits, rateLimitConsume, requestDuration };
export default routes;
