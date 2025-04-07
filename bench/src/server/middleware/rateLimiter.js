/**
 * Rate Limiting Middleware
 * Handles rate limiting for API endpoints
 */

const config = require('../config');

/**
 * Creates a middleware function that implements rate limiting
 * @param {Object} rateLimiter - The rate limiter instance
 * @param {Object} metrics - The metrics tracking object
 * @returns {Function} Middleware function
 */
function createRateLimitMiddleware(rateLimiter, metrics) {
  return async (request, reply) => {
    try {
      // Use unique identifier for each client
      // Combine IP with optional user-id header for more granular rate limiting
      const userId = request.headers['user-id'] || request.ip;
      const endpoint = request.url; // Track rate limits per endpoint
      const key = `${userId}:${endpoint}`;

      try {
        // Consume different points based on endpoint type
        const pointsToConsume = request.url.includes('/heavy') ? 2 : 1;

        // For distributed rate limiting, we can customize duration for specific endpoints
        const customDuration = request.url.includes('/heavy') ? config.duration * 1.5 : config.duration;

        // Attempt to consume points
        const rateLimiterRes = await rateLimiter.consume(key, pointsToConsume, {
          customDuration
        });

        // Add rate limiting headers to response
        reply.header('X-RateLimit-Limit', config.rateLimit);
        reply.header('X-RateLimit-Remaining', rateLimiterRes.remainingPoints);
        reply.header('X-RateLimit-Reset', new Date(Date.now() + rateLimiterRes.msBeforeNext).toISOString());

        // Continue to the route handler
      } catch (rejRes) {
        if (rejRes instanceof Error) {
          console.error('Rate limiter error:', rejRes);
          metrics.errors++;
          return reply.code(500).send({ error: 'Internal Server Error' });
        }

        // Rate limited - return appropriate headers and status
        metrics.rejectedRequests++;

        const retryAfter = Math.ceil(rejRes.msBeforeNext / 1000) || 1;

        reply
          .code(429)
          .header('X-RateLimit-Limit', config.rateLimit)
          .header('X-RateLimit-Remaining', 0)
          .header('X-RateLimit-Reset', new Date(Date.now() + rejRes.msBeforeNext).toISOString())
          .header('Retry-After', retryAfter)
          .send({
            error: 'Too Many Requests',
            retryAfter,
            message: `Rate limit exceeded. Try again in ${retryAfter} seconds.`
          });
      }
    } catch (error) {
      console.error('Rate limit middleware error:', error);
      metrics.errors++;
      return reply.code(500).send({ error: 'Internal Server Error' });
    }
  };
}

module.exports = createRateLimitMiddleware;
