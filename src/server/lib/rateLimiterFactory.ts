/**
 * Rate Limiter Factory
 * Creates appropriate rate limiter instances based on configuration
 */
import {
  RateLimiterRedis,
  RateLimiterValkey,
  RateLimiterValkeyGlide,
  RateLimiterAbstract,
  RateLimiterRes,
} from "rate-limiter-flexible";
import { createClient, closeClient } from "./clientFactory.js";
import { getConfig } from "../config/index.js";

const config = getConfig();

let rateLimiter: RateLimiterAbstract | null = null;

/**
 * Creates a rate limiter instance based on the configuration
 */
export async function createRateLimiter(): Promise<RateLimiterAbstract> {
  if (rateLimiter) {
    return rateLimiter;
  }

  const client = await createClient();
  const rateLimitOptions = {
    storeClient: client,
    points: config.rateLimiter.points,
    duration: config.rateLimiter.duration,
    blockDuration: config.rateLimiter.blockDuration,
  };

  // Select the appropriate rate limiter implementation based on mode
  switch (config.mode) {
    case "valkey-glide":
      console.log("Using RateLimiterGlide");
      rateLimiter = new RateLimiterValkeyGlide(rateLimitOptions);
      break;

    case "iovalkey":
      console.log("Using RateLimiterValkey");
      rateLimiter = new RateLimiterValkey(rateLimitOptions);
      break;
    case "ioredis":
      console.log("Using RateLimiterRedis");
      rateLimiter = new RateLimiterRedis(rateLimitOptions);
      break;
    default:
      throw new Error(`Unsupported mode: ${config.mode}`);
  }

  return rateLimiter;
}

/**
 * Gets the current rate limiter instance
 */
export function getRateLimiter(): RateLimiterAbstract | null {
  return rateLimiter;
}

/**
 * Consumes a rate limit point for the given key
 */
export async function consumePoint(key: string): Promise<RateLimiterRes> {
  if (!rateLimiter) {
    throw new Error("Rate limiter not initialized");
  }

  return rateLimiter.consume(key);
}

/**
 * Resets rate limit for a key
 */
export async function resetPoint(key: string): Promise<void> {
  if (!rateLimiter) {
    throw new Error("Rate limiter not initialized");
  }

  await rateLimiter.delete(key);
}

/**
 * Closes the rate limiter connection
 */
export async function closeRateLimiter(): Promise<void> {
  if (rateLimiter) {
    await closeClient();
    rateLimiter = null;
  }
}
