import { FastifyRequest, FastifyReply } from "fastify";
import { getRateLimiter, consumePoint } from "../lib/rateLimiterFactory.js";
import { RateLimiterRes } from "rate-limiter-flexible";
import { rateLimitHits } from "../routes/index.js"; // Import the counter
import { getConfig } from "../config/index.js"; // Import config

const config = getConfig(); // Get config for rate limiter mode label

export async function rateLimiter(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  const limiter = getRateLimiter(); // Renamed to avoid conflict

  if (!limiter) {
    request.log.error("Rate limiter not initialized"); // Use request logger
    return reply.code(500).send("Server error");
  }

  try {
    // Use userId from query string if present, otherwise fall back to IP
    const userId = (request.query as { userId?: string })?.userId;
    const key = userId || request.ip || "127.0.0.1"; // Ensure fallback

    await consumePoint(key);

    // Rate limit request successful - continue to the handler
  } catch (error) {
    if (error instanceof RateLimiterRes) {
      // Rate limit hit
      const rateLimiterRes = error as RateLimiterRes;
      const seconds = Math.round(rateLimiterRes.msBeforeNext / 1000) || 1;

      // Log the rate limit hit and increment the counter
      const userId = (request.query as { userId?: string })?.userId;
      const key = userId || request.ip || "127.0.0.1";
      request.log.warn(
        `Rate limit exceeded for key: ${key} - Incrementing rateLimitHits.`
      );
      rateLimitHits.inc({ rate_limiter: config.mode }); // Increment counter

      reply.header("Retry-After", String(seconds));
      reply.header("X-RateLimit-Reset", String(seconds));
      reply.header("X-RateLimit-Remaining", "0");

      return reply
        .code(429)
        .send(`Too Many Requests: Retry after ${seconds} seconds`);
    } else {
      // Handle other potential errors during rate limit check
      request.log.error("Error during rate limit consumption:", error);
      return reply.code(500).send("Server error during rate limit check");
    }
  }
}
