/**
 * Server configuration
 * Loads and validates environment variables
 */

const os = require('os');

// Environment configuration with defaults
const config = {
  // Server settings
  port: parseInt(process.env.PORT || '3000', 10),

  // Redis connection
  redisHost: process.env.REDIS_HOST || 'localhost',
  redisPort: parseInt(process.env.REDIS_PORT || '6379', 10),

  // Valkey connection
  valkeyHost: process.env.VALKEY_HOST || 'localhost',
  valkeyPort: parseInt(process.env.VALKEY_PORT || '8080', 10),

  // Cluster configuration
  useCluster: (process.env.USE_CLUSTER || 'false').toLowerCase() === 'true',

  // Redis/Valkey Cluster configurations
  useRedisCluster: (process.env.USE_REDIS_CLUSTER || 'false').toLowerCase() === 'true',
  useValkeyCluster: (process.env.USE_VALKEY_CLUSTER || 'false').toLowerCase() === 'true',

  // Cluster nodes configuration
  clusterNodes: process.env.CLUSTER_NODES
    ? JSON.parse(process.env.CLUSTER_NODES)
    : [
      // Default cluster configuration with 3 shards (primary + replica for each)
        { host: 'redis-node1', port: 6379 },
        { host: 'redis-node2', port: 6379 },
        { host: 'redis-node3', port: 6379 },
        { host: 'redis-node4', port: 6379 },
        { host: 'redis-node5', port: 6379 },
        { host: 'redis-node6', port: 6379 }
      ],

  // Valkey cluster nodes configuration (can be different from Redis)
  valkeyClusterNodes: process.env.VALKEY_CLUSTER_NODES
    ? JSON.parse(process.env.VALKEY_CLUSTER_NODES)
    : [
        { host: 'valkey-node1', port: 8080 },
        { host: 'valkey-node2', port: 8080 },
        { host: 'valkey-node3', port: 8080 },
        { host: 'valkey-node4', port: 8080 },
        { host: 'valkey-node5', port: 8080 },
        { host: 'valkey-node6', port: 8080 }
      ],

  // Rate limiter options
  mode: process.env.MODE || 'valkey-glide', // Default to valkey-glide
  rateLimit: parseInt(process.env.RATE_LIMIT || '100', 10),
  duration: parseInt(process.env.DURATION || '60', 10),

  // Concurrency options (for Node.js cluster, not Redis/Valkey clusters)
  workers: parseInt(process.env.WORKERS || os.cpus().length.toString(), 10)
};

module.exports = config;
