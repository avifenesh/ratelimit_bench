import {
  FastifyInstance,
  RouteShorthandOptions,
  FastifyRequest,
} from "fastify";
import { RateLimiterAbstract } from "rate-limiter-flexible";
import { createRateLimiter } from "../lib/rateLimiterFactory.js";
import { getConfig } from "../config/index.js";
import { performHeavyComputation } from "../lib/utils.js";

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
      onExceeded: (request: FastifyRequest, key: string) => {
        fastify.log.warn(`Rate limit exceeded for key: ${key}`);
      },
    },
  };

  fastify.get("/light", { ...options, ...rateLimitOpts }, async (_request) => {
    try {
      return { message: "Light workload processed" };
    } catch (error) {
      fastify.log.error("Error processing light workload:", error);
      throw error;
    }
  });

  fastify.get("/heavy", { ...options, ...rateLimitOpts }, async (_request) => {
    try {
      performHeavyComputation(100); // Simulate heavy work
      return { message: "Heavy workload processed" };
    } catch (error) {
      fastify.log.error("Error processing heavy workload:", error);
      throw error;
    }
  });
}
