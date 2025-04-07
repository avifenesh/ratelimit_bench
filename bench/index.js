/**
 * Benchmark entry point for rate limiter implementations
 */
import { RateLimiterRedis, RateLimiterValkey, RateLimiterValkeyGlide, RateLimiterMemory } from 'rate-limiter-flexible';

// Export all rate limiters
export default {
  RateLimiterRedis,
  RateLimiterValkey,
  RateLimiterValkeyGlide,
  RateLimiterMemory
};
