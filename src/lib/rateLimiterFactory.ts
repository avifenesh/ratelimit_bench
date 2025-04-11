import { RateLimiterRedis, RateLimiterMemory } from "rate-limiter-flexible";
import { createClient } from "./clientFactory.js";
import type { Config } from "../server/config/index.js";

/**
 * Creates an appropriate rate limiter based on the specified mode
 * Prioritizes Valkey implementations, particularly Valkey Glide
 */
export function createRateLimiter(mode: string, config: Config) {
  // Extract cluster mode from the mode string (e.g., 'valkey-glide:cluster')
  const [baseMode, clusterMode] = mode.split(":");
  const useCluster = clusterMode === "cluster";

  // Default rate limiting options
  const points = config.rateLimiter.points;
  const duration = config.rateLimiter.duration;
  const blockDuration = config.rateLimiter.blockDuration;

  switch (baseMode) {
    case "valkey-glide": {
      // Valkey Glide implementation (primary focus)
      const redisClient = createClient("valkey-glide", {
        ...config.valkey,
        cluster: useCluster,
      });

      return new RateLimiterRedis({
        storeClient: redisClient,
        points,
        duration,
        blockDuration,
        keyPrefix: "rlflx:valkey-glide",
      });
    }

    case "valkey-io": {
      // Valkey IO implementation (secondary focus)
      const redisClient = createClient("valkey-io", {
        ...config.valkey,
        cluster: useCluster,
      });

      return new RateLimiterRedis({
        storeClient: redisClient,
        points,
        duration,
        blockDuration,
        keyPrefix: "rlflx:valkey-io",
      });
    }

    case "ioredis": {
      // Redis IORedis implementation
      const redisClient = createClient("ioredis", {
        ...config.redis,
        cluster: useCluster,
      });

      return new RateLimiterRedis({
        storeClient: redisClient,
        points,
        duration,
        blockDuration,
        keyPrefix: "rlflx:ioredis",
      });
    }

    default:
      // Fallback to memory-based rate limiter
      console.warn(
        `Unknown rate limiter mode: ${mode}, using memory-based rate limiter instead`
      );
      return new RateLimiterMemory({
        points,
        duration,
        blockDuration,
      });
  }
}
