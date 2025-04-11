import { GlideClient, GlideClusterClient, Logger } from "@valkey/valkey-glide";
import { Redis as IORedis, Cluster as RedisCluster } from "ioredis";
import { Redis as IOValkey, Cluster as ValkeyCluster } from "iovalkey";

// Disable verbose Glide logging for better performance
Logger.init("off");

interface ClientOptions {
  host: string;
  port: number;
  password?: string;
  cluster: boolean;
  clusterNodes?: string[];
  db?: number;
}

/**
 * Creates the appropriate database client based on the specified type
 * Prioritizes Valkey implementations, particularly Valkey Glide
 */
export function createClient(type: string, options: ClientOptions) {
  const { host, port, password, cluster, clusterNodes } = options;

  // Set default optimized connection options
  const commonOptions = {
    db: options.db || 0,
    password: password || undefined,
    connectTimeout: 5000,
    commandTimeout: 3000,
  };

  switch (type) {
    case "valkey-glide": {
      // Primary focus: Valkey with Glide client
      if (cluster && clusterNodes && clusterNodes.length > 0) {
        // Create cluster client
        return GlideClusterClient.createClient({
          addresses: clusterNodes.map((node) => {
            const [host, port] = node.split(":");
            return { host, port: parseInt(port, 10) };
          }),
          useTLS: false,
          ...commonOptions,
        });
      } else {
        // Create standalone client
        return GlideClient.createClient({
          addresses: [{ host, port }],
          ...commonOptions,
        });
      }
    }

    case "valkey-io": {
      // Secondary focus: Valkey with IOValkey client (based on ioredis API)
      if (cluster && clusterNodes && clusterNodes.length > 0) {
        // Create cluster client with proper instantiation
        const formattedNodes = clusterNodes.map((node) => {
          const [host, port] = node.split(":");
          return { host, port: parseInt(port, 10) };
        });

        // Use the factory pattern for both Redis and Valkey clients
        return new ValkeyCluster(formattedNodes, {
          scaleReads: "all",
          maxRedirections: 16,
          ...commonOptions,
          retryDelayOnFailover: 300,
          retryDelayOnClusterDown: 500,
        });
      } else {
        // Create standalone client with proper instantiation
        return new IOValkey({
          host,
          port,
          ...commonOptions,
          retryStrategy: (times: number) => Math.min(times * 200, 2000),
        });
      }
    }

    case "ioredis": {
      // Redis with IORedis client
      if (cluster && clusterNodes && clusterNodes.length > 0) {
        // Create cluster client
        return new RedisCluster(
          clusterNodes.map((node) => {
            const [host, port] = node.split(":");
            return { host, port: parseInt(port, 10) };
          }),
          {
            scaleReads: "all",
            maxRedirections: 10,
            ...commonOptions,
            retryDelayOnFailover: 500,
            retryDelayOnClusterDown: 1000,
          }
        );
      } else {
        // Create standalone client
        return new IORedis({
          host,
          port,
          ...commonOptions,
          retryStrategy: (times: number) => Math.min(times * 300, 3000),
        });
      }
    }

    default:
      throw new Error(`Unsupported client type: ${type}`);
  }
}
