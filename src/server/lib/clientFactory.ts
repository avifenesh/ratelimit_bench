/**
 * Client Factory
 * Creates appropriate Redis/Valkey clients based on configuration
 */

import * as ioredis from "ioredis";
import { Redis as Valkey, Cluster as iovalkeyCluster } from "iovalkey";
import { GlideClient, GlideClusterClient, Logger } from "@valkey/valkey-glide";
import config from "../config/index.js";

// Define a common client type alias
type RateLimiterClient =
  | ioredis.Redis
  | ioredis.Cluster
  | Valkey
  | iovalkeyCluster
  | GlideClient
  | GlideClusterClient;

// Singleton client instance
let clientInstance: RateLimiterClient | null = null;

/**
 * Creates an appropriate client for the selected mode
 * @returns {Promise<RateLimiterClient>} The connected client instance
 */
export async function createClient(): Promise<RateLimiterClient> {
  // Return existing client if available
  if (clientInstance) {
    return clientInstance;
  }

  switch (config.mode) {
    case "valkey-glide": {
      // Turn off logging for performance optimization
      Logger.init("off");

      if (config.useValkeyCluster) {
        console.log("Connecting to Valkey Cluster using valkey-glide client");

        // Configure cluster options with optimized settings
        clientInstance = await GlideClusterClient.createClient({
          addresses: config.valkeyClusterNodes.map((node) => ({
            host: node.host,
            port: node.port,
          })),
          // Optimized settings for Valkey Cluster
          useTLS: false,
          requestTimeout: 3000,
          advancedConfiguration: {
            connectionTimeout: 5000,
          },
          periodicChecks: {
            duration_in_sec: 30,
          },
        });
      } else {
        console.log(
          `Connecting to Valkey at ${config.valkeyHost}:${config.valkeyPort} using valkey-glide client`
        );

        // Configure standalone options with optimized settings
        clientInstance = await GlideClient.createClient({
          addresses: [
            {
              host: config.valkeyHost,
              port: config.valkeyPort,
            },
          ],
          databaseId: config.valkeyDb || 0,
          requestTimeout: 3000,
          advancedConfiguration: {
            connectionTimeout: 5000,
          },
        });
      }
      break;
    }

    case "valkey-io": {
      if (config.useValkeyCluster) {
        console.log("Connecting to Valkey Cluster using iovalkey client");

        clientInstance = new iovalkeyCluster(
          config.valkeyClusterNodes.map((node) => ({
            host: node.host,
            port: node.port,
          })),
          {
            redisOptions: {
              db: config.valkeyDb,
              connectTimeout: 5000,
              maxRetriesPerRequest: 3,
              offlineQueue: true,
            },
            // Slightly better defaults for Valkey IO
            scaleReads: "all",
            maxRedirections: 16,
            retryDelayOnFailover: 100,
          }
        );
      } else {
        console.log(
          `Connecting to Valkey at ${config.valkeyHost}:${config.valkeyPort} using iovalkey client`
        );

        clientInstance = new Valkey({
          host: config.valkeyHost,
          port: config.valkeyPort,
          db: config.valkeyDb,
          connectTimeout: 5000,
          maxRetriesPerRequest: 3,
          offlineQueue: true,
        });
      }
      break;
    }

    case "redis-ioredis": {
      if (config.useRedisCluster) {
        console.log("Connecting to Redis Cluster using ioredis");

        clientInstance = new ioredis.Cluster(
          config.redisClusterNodes.map((node) => ({
            host: node.host,
            port: node.port,
          })),
          {
            redisOptions: {
              db: config.redisDb,
              connectTimeout: 5000,
              maxRetriesPerRequest: 3,
              offlineQueue: true,
            },
            scaleReads: "slave",
            maxRedirections: 16,
            retryDelayOnFailover: 150,
          }
        );
      } else {
        console.log(
          `Connecting to Redis at ${config.redisHost}:${config.redisPort} using ioredis`
        );

        clientInstance = new ioredis.Redis({
          host: config.redisHost,
          port: config.redisPort,
          db: config.redisDb,
          connectTimeout: 5000,
          maxRetriesPerRequest: 3,
          offlineQueue: true,
        });
      }
      break;
    }

    default: {
      console.log(
        `Unknown mode ${config.mode}, defaulting to valkey-glide standalone`
      );
      Logger.init("off");

      clientInstance = await GlideClient.createClient({
        addresses: [
          {
            host: config.valkeyHost,
            port: config.valkeyPort,
          },
        ],
        databaseId: config.valkeyDb || 0,
        requestTimeout: 3000,
        advancedConfiguration: {
          connectionTimeout: 5000,
        },
      });
      Logger.init("off");
    }
  }

  return clientInstance;
}

/**
 * Returns the current client instance without creating a new one
 */
export function getClient(): RateLimiterClient | null {
  return clientInstance;
}

/**
 * Closes the client connection gracefully
 */
export async function closeClient(): Promise<void> {
  if (!clientInstance) return;

  try {
    if (
      clientInstance instanceof GlideClient ||
      clientInstance instanceof GlideClusterClient
    ) {
      clientInstance.close();
    } else if (
      clientInstance instanceof ioredis.Redis ||
      clientInstance instanceof ioredis.Cluster ||
      clientInstance instanceof Valkey ||
      clientInstance instanceof iovalkeyCluster
    ) {
      clientInstance.disconnect();
    }
  } catch (err) {
    console.error("Error closing client:", err);
  } finally {
    clientInstance = null;
  }
}
