/**
 * Server configuration
 * Loads and validates environment variables
 */

export interface Config {
  port: number;
  mode: string;
  logLevel: string;
  redis: {
    host: string;
    port: number;
    cluster: boolean;
    clusterNodes?: string[];
  };
  valkey: {
    host: string;
    port: number;
    cluster: boolean;
    clusterNodes?: string[];
  };
  rateLimiter: {
    points: number;
    duration: number;
    blockDuration: number;
  };
  scenario?: string;
}

export function getConfig(): Config {
  // Parse rate limiter mode (valkey-glide, valkey-io, ioredis, etc.)
  const mode = process.env.MODE || "valkey-glide";

  // Parse Redis cluster configuration
  const useRedisCluster = process.env.USE_REDIS_CLUSTER === "true";
  let redisClusterNodes: string[] = [];
  if (useRedisCluster && process.env.REDIS_CLUSTER_NODES) {
    redisClusterNodes = process.env.REDIS_CLUSTER_NODES.split(",");
  }

  // Parse Valkey cluster configuration
  const useValkeyCluster = process.env.USE_VALKEY_CLUSTER === "true";
  let valkeyClusterNodes: string[] = [];
  if (useValkeyCluster && process.env.VALKEY_CLUSTER_NODES) {
    valkeyClusterNodes = process.env.VALKEY_CLUSTER_NODES.split(",");
  }

  return {
    port: parseInt(process.env.PORT || "3000", 10),
    mode,
    logLevel: process.env.LOG_LEVEL || "info",
    redis: {
      host: process.env.REDIS_HOST || "localhost",
      port: parseInt(process.env.REDIS_PORT || "6379", 10),
      cluster: useRedisCluster,
      clusterNodes: redisClusterNodes,
    },
    valkey: {
      host: process.env.VALKEY_HOST || "localhost",
      port: parseInt(process.env.VALKEY_PORT || "8080", 10),
      cluster: useValkeyCluster,
      clusterNodes: valkeyClusterNodes,
    },
    rateLimiter: {
      points: parseInt(process.env.RATE_LIMIT_POINTS || "100", 10),
      duration: parseInt(process.env.RATE_LIMIT_DURATION || "60", 10),
      blockDuration: parseInt(process.env.RATE_LIMIT_BLOCK_DURATION || "0", 10),
    },
    scenario: process.env.SCENARIO || "light",
  };
}
