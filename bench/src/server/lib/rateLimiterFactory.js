/**
 * Rate Limiter Factory
 * Creates appropriate rate limiter instances based on configuration
 */

const {
  RateLimiterValkey,
  RateLimiterValkeyGlide,
  RateLimiterRedis
} = require('rate-limiter-flexible');
const config = require('../config');

/**
 * Creates a rate limiter based on the selected mode
 * @param {Object} client - Redis/Valkey client
 * @returns {Object} The rate limiter instance
 */
function createRateLimiter(client) {
  let rateLimiter;

  const options = {
    storeClient: client,
    points: config.rateLimit,
    duration: config.duration,
    keyPrefix: `ratelimit:${config.mode}`
  };

  switch (config.mode) {
    case 'valkey-glide':
      rateLimiter = new RateLimiterValkeyGlide(options);
      break;

    case 'valkey-io':
      rateLimiter = new RateLimiterValkey(options);
      break;

    case 'redis-ioredis':
      rateLimiter = new RateLimiterRedis(options);
      break;

    case 'redis-node':
      rateLimiter = new RateLimiterRedis({
        ...options,
        useRedisPackage: true
      });
      break;

    default:
      rateLimiter = new RateLimiterValkeyGlide(options);
  }

  return rateLimiter;
}

/**
 * Closes the rate limiter if it has a close method
 * @param {Object} rateLimiter - The rate limiter to close
 * @returns {Promise<void>}
 */
async function closeRateLimiter(rateLimiter) {
  if (rateLimiter && typeof rateLimiter.close === 'function') {
    try {
      await rateLimiter.close();
    } catch (err) {
      console.error('Error closing rate limiter:', err);
    }
  }
}

module.exports = {
  createRateLimiter,
  closeRateLimiter
};
