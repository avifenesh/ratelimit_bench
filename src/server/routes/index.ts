import {
  FastifyInstance,
  RouteShorthandOptions,
  FastifyRequest,
} from "fastify";
import { RateLimiterAbstract, RateLimiterRes } from "rate-limiter-flexible";
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
  let rateLimiter: RateLimiterAbstract;

  try {
    rateLimiter = await createRateLimiter();
    fastify.log.info(`Rate limiter initialized with type: ${config.mode}`);
  } catch (error) {
    fastify.log.error("Failed to initialize rate limiter:", error);
    process.exit(1);
  }

  // Prometheus metrics endpoint
  fastify.get("/metrics", async (_request, reply) => {
    reply.header("Content-Type", registerMetrics.contentType);
    return registerMetrics.metrics();
  });

  const rateLimitOpts = {
    rateLimit: {
      max: config.rateLimiter.points,
      timeWindow: config.rateLimiter.duration * 1000,
      keyGenerator: (request: FastifyRequest) => request.ip,
      addHeaders: {
        "X-RateLimit-Limit": true,
        "X-RateLimit-Remaining": true,
        "X-RateLimit-Reset": true,
        "Retry-After": true,
      },
      rateLimiter: rateLimiter,
      onExceeded: (_request: FastifyRequest, key: string) => {
        fastify.log.warn(`Rate limit exceeded for key: ${key}`);
        // Track rate limit hit when exceeded
        rateLimitHits.inc({ rate_limiter: config.mode });
      },
    },
  };

  fastify.get(
    "/light",
    { ...options, ...rateLimitOpts },
    async (_request, _reply) => {
      const start = performance.now();
      try {
        // Track consumption when not rate limited
        rateLimitConsumptions.inc({ rate_limiter: config.mode });

        const responseData = { message: "Light workload processed" };

        // Record request duration
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
        // Check if this is a rate limit error
        if (error instanceof RateLimiterRes) {
          // Rate limit was exceeded - this should be handled by the rate limit plugin,
          // but we can also track it here for completeness
          rateLimitHits.inc({ rate_limiter: config.mode });

          const duration = (performance.now() - start) / 1000;
          httpRequestDuration.observe(
            {
              method: "GET",
              route: "/light",
              status_code: 429,
              rate_limiter: config.mode,
            },
            duration
          );

          throw error;
        }

        // Other errors
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
    }
  );

  fastify.get(
    "/heavy",
    { ...options, ...rateLimitOpts },
    async (_request, _reply) => {
      const start = performance.now();
      try {
        // Track consumption when not rate limited
        rateLimitConsumptions.inc({ rate_limiter: config.mode });

        performHeavyComputation(100); // Simulate heavy work
        const responseData = { message: "Heavy workload processed" };

        // Record request duration
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
        // Check if this is a rate limit error
        if (error instanceof RateLimiterRes) {
          // Rate limit was exceeded - this should be handled by the rate limit plugin,
          // but we can also track it here for completeness
          rateLimitHits.inc({ rate_limiter: config.mode });

          const duration = (performance.now() - start) / 1000;
          httpRequestDuration.observe(
            {
              method: "GET",
              route: "/heavy",
              status_code: 429,
              rate_limiter: config.mode,
            },
            duration
          );

          throw error;
        }

        // Other errors
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
    }
  );
}
