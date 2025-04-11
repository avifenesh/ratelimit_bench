import { FastifyRequest, FastifyReply } from "fastify";
import { getRateLimiter, consumePoint } from "../lib/rateLimiterFactory.js";
import { RateLimiterRes } from "rate-limiter-flexible";
import { rateLimitHits, rateLimitConsumptions } from "../routes/index.js";
import { getConfig } from "../config/index.js";

const config = getConfig();

/**
 * Rate limiter middleware for Fastify.
 * @param request - The Fastify request object.
 * @param reply - The Fastify reply object.
 */
export async function rateLimiter(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  const rateLimiter = getRateLimiter();

  if (!rateLimiter) {
    console.error("Rate limiter not initialized");
    return reply.code(500).send("Server error");
  }

  try {
    // Get the client IP address
    const ip = request.ip || "127.0.0.1";
    await consumePoint(ip);

    // Increment the consume counter with current mode as label
    rateLimitConsumptions.inc({ rate_limiter: config.mode });
  } catch (error) {
    // Rate limit hit - track this in metrics
    rateLimitHits.inc({ rate_limiter: config.mode });

    const rateLimiterRes = error as RateLimiterRes;
    const seconds = Math.round(rateLimiterRes.msBeforeNext / 1000) || 1;
    reply.header("Retry-After", String(seconds));
    return reply
      .code(429)
      .send(`Too Many Requests: Retry after ${seconds} seconds`);
  }
}
