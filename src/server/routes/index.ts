import type { FastifyInstance } from "fastify";
import { RateLimiterRes, RateLimiterAbstract } from "rate-limiter-flexible";
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

interface RouteOptions {
  rateLimiter: RateLimiterAbstract;
  config: {
    mode: string;
    scenario?: string;
  };
}

// Heavy CPU workload function for testing performance under load
function heavyComputation(iterations: number = 100000): number {
  let result = 0;
  for (let i = 0; i < iterations; i++) {
    // Deliberately inefficient computation to simulate CPU load
    result += Math.sqrt(Math.pow(i, 2) + Math.sin(i) + Math.cos(i));
  }
  return result;
}

export function registerRoutes(app: FastifyInstance, options: RouteOptions) {
  const { rateLimiter, config } = options;
  const rateLimiterType = config.mode;
  const scenario = config.scenario || "light";

  // Prometheus metrics endpoint
  app.get("/metrics", async (request, reply) => {
    reply.header("Content-Type", registerMetrics.contentType);
    return registerMetrics.metrics();
  });

  // Health check endpoint (not rate limited)
  app.get("/health", async (_request) => {
    return { status: "ok", mode: rateLimiterType };
  });

  // Main API endpoint with rate limiting
  app.get(
    "/api",
    {
      schema: {
        querystring: {
          type: "object",
          properties: {
            userId: { type: "string" },
          },
        },
      },
    },
    async (request, reply) => {
      const start = performance.now();
      const { userId = "default" } = request.query as { userId?: string };

      try {
        // Try to consume a point from the rate limiter
        await rateLimiter.consume(userId);

        // Track consumption
        rateLimitConsumptions.inc({ rate_limiter: rateLimiterType });

        // Generate response based on scenario
        let responseData: unknown;

        if (scenario === "heavy") {
          // Heavy CPU-bound workload
          const result = heavyComputation(500000);
          responseData = {
            message: "Heavy workload completed",
            computationResult: result,
            timestamp: new Date().toISOString(),
          };
        } else {
          // Light workload - just a simple response
          responseData = {
            message: "Request successful",
            timestamp: new Date().toISOString(),
          };
        }

        // Record request duration
        const duration = (performance.now() - start) / 1000;
        httpRequestDuration.observe(
          {
            method: "GET",
            route: "/api",
            status_code: 200,
            rate_limiter: rateLimiterType,
          },
          duration
        );

        return responseData;
      } catch (error) {
        // Handle rate limit exceeded
        if (error instanceof RateLimiterRes) {
          // Track rate limit hit
          rateLimitHits.inc({ rate_limiter: rateLimiterType });

          // Return rate limit response
          const duration = (performance.now() - start) / 1000;
          httpRequestDuration.observe(
            {
              method: "GET",
              route: "/api",
              status_code: 429,
              rate_limiter: rateLimiterType,
            },
            duration
          );

          return reply
            .code(429)
            .header("Retry-After", Math.floor(error.msBeforeNext / 1000))
            .send({
              error: "Too Many Requests",
              retryAfter: Math.ceil(error.msBeforeNext / 1000),
            });
        }

        // Handle other errors
        request.log.error(error);

        const duration = (performance.now() - start) / 1000;
        httpRequestDuration.observe(
          {
            method: "GET",
            route: "/api",
            status_code: 500,
            rate_limiter: rateLimiterType,
          },
          duration
        );

        return reply.code(500).send({ error: "Internal Server Error" });
      }
    }
  );

  // Echo endpoint that returns the request body (for testing)
  app.post("/api/echo", async (request, reply) => {
    const start = performance.now();
    const { userId = "default" } = request.query as { userId?: string };

    try {
      // Try to consume a point from the rate limiter
      await rateLimiter.consume(userId);

      // Track consumption
      rateLimitConsumptions.inc({ rate_limiter: rateLimiterType });

      // Return the request body
      const duration = (performance.now() - start) / 1000;
      httpRequestDuration.observe(
        {
          method: "POST",
          route: "/api/echo",
          status_code: 200,
          rate_limiter: rateLimiterType,
        },
        duration
      );

      return request.body;
    } catch (error) {
      // Handle rate limit exceeded
      if (error instanceof RateLimiterRes) {
        // Track rate limit hit
        rateLimitHits.inc({ rate_limiter: rateLimiterType });

        // Return rate limit response
        const duration = (performance.now() - start) / 1000;
        httpRequestDuration.observe(
          {
            method: "POST",
            route: "/api/echo",
            status_code: 429,
            rate_limiter: rateLimiterType,
          },
          duration
        );

        return reply
          .code(429)
          .header("Retry-After", Math.floor(error.msBeforeNext / 1000))
          .send({
            error: "Too Many Requests",
            retryAfter: Math.ceil(error.msBeforeNext / 1000),
          });
      }

      // Handle other errors
      request.log.error(error);

      const duration = (performance.now() - start) / 1000;
      httpRequestDuration.observe(
        {
          method: "POST",
          route: "/api/echo",
          status_code: 500,
          rate_limiter: rateLimiterType,
        },
        duration
      );

      return reply.code(500).send({ error: "Internal Server Error" });
    }
  });
}
