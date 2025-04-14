import { FastifyInstance, RouteShorthandOptions } from "fastify";
import { createRateLimiter } from "../lib/rateLimiterFactory.js";
import { getConfig } from "../config/index.js";
import { performHeavyComputation } from "../lib/utils.js";
import { register as registerMetrics, Counter, Histogram } from "prom-client";

// Prometheus metrics
const httpRequestDuration = new Histogram({
  name: "http_request_duration_seconds",
  help: "Duration of HTTP requests in seconds",
  labelNames: ["method", "route", "status_code", "rate_limiter"],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2, 5],
});

export const rateLimitHits = new Counter({
  name: "rate_limit_hits_total",
  help: "Total number of rate limit hits",
  labelNames: ["rate_limiter"],
});

export const rateLimitConsumptions = new Counter({
  name: "rate_limit_consumptions_total",
  help: "Total number of rate limit consumptions",
  labelNames: ["rate_limiter"],
});

const config = getConfig();

export default async function routes(
  fastify: FastifyInstance,
  options: RouteShorthandOptions
) {
  try {
    await createRateLimiter();
    fastify.log.info(`Rate limiter type: ${config.mode}`);
  } catch (error) {
    fastify.log.error("Failed to initialize rate limiter:", error);
    process.exit(1);
  }

  // Prometheus metrics endpoint
  fastify.get("/metrics", async (_request, reply) => {
    reply.header("Content-Type", registerMetrics.contentType);
    return registerMetrics.metrics();
  });

  fastify.get("/light", options, async (_request, _reply) => {
    const start = performance.now();
    try {
      rateLimitConsumptions.inc({ rate_limiter: config.mode });

      const responseData = { message: "Light workload processed" };

      const duration = (performance.now() - start) / 1000;
      httpRequestDuration.observe(
        {
          method: "GET",
          route: "/light",
          status_code: 200,
          rate_limiter: config.mode,
        },
        duration
      );

      return responseData;
    } catch (error) {
      fastify.log.error("Error processing light workload:", error);

      const duration = (performance.now() - start) / 1000;
      httpRequestDuration.observe(
        {
          method: "GET",
          route: "/light",
          status_code: 500,
          rate_limiter: config.mode,
        },
        duration
      );

      throw error;
    }
  });

  fastify.get("/heavy", options, async (_request, _reply) => {
    const start = performance.now();
    try {
      rateLimitConsumptions.inc({ rate_limiter: config.mode });

      performHeavyComputation(100);
      const responseData = { message: "Heavy workload processed" };

      const duration = (performance.now() - start) / 1000;
      httpRequestDuration.observe(
        {
          method: "GET",
          route: "/heavy",
          status_code: 200,
          rate_limiter: config.mode,
        },
        duration
      );

      return responseData;
    } catch (error) {
      fastify.log.error("Error processing heavy workload:", error);

      const duration = (performance.now() - start) / 1000;
      httpRequestDuration.observe(
        {
          method: "GET",
          route: "/heavy",
          status_code: 500,
          rate_limiter: config.mode,
        },
        duration
      );

      throw error;
    }
  });
}
