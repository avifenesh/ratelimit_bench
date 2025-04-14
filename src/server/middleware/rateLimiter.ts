import { FastifyRequest, FastifyReply } from "fastify";
import { getRateLimiter, consumePoint } from "../lib/rateLimiterFactory.js";
import { RateLimiterRes } from "rate-limiter-flexible";
import { rateLimitHits } from "../routes/index.js";
import { getConfig } from "../config/index.js";
const config = getConfig();

export async function rateLimiter(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  const limiter = getRateLimiter();

  if (!limiter) {
    request.log.error("Rate limiter not initialized");
    return reply.code(500).send("Server error");
  }

  try {
    const userId = (request.query as { userId?: string })?.userId;
    const key = userId || request.ip || "127.0.0.1";

    await consumePoint(key);
  } catch (error) {
    if (error instanceof RateLimiterRes) {
      const rateLimiterRes = error as RateLimiterRes;
      const seconds = Math.round(rateLimiterRes.msBeforeNext / 1000) || 1;

      rateLimitHits.inc({ rate_limiter: config.mode });
      reply.header("Retry-After", String(seconds));
      reply.header("X-RateLimit-Reset", String(seconds));
      reply.header("X-RateLimit-Remaining", "0");

      return reply
        .code(429)
        .send(`Too Many Requests: Retry after ${seconds} seconds`);
    } else {
      request.log.error("Error during rate limit consumption:", error);
      return reply.code(500).send("Server error during rate limit check");
    }
  }
}
