/**
 * Client Factory
 * Creates appropriate Redis/Valkey clients based on configuration
 */

import * as ioredis from "ioredis";
import * as Redis from "redis";
import Valkey from "iovalkey";
import { GlideClient, GlideClusterClient, Logger } from "@valkey/valkey-glide";
import config from "../config/index.js";

// Define a common client type alias
type RateLimiterClient =
  | Redis.Redis
  | Redis.Cluster
  | Redis.RedisClientType
  | Valkey.Valkey
  | Valkey.Cluster
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

        clientInstance = new Valkey.Cluster(
          config.valkeyClusterNodes.map((node) => ({
            host: node.host,
            port: node.port,
          })),
          {
            redisOptions: {
              db: config.valkeyDb,
              connectTimeout: 5000,
              maxRetriesPerRequest: 3,
              enableOfflineQueue: true,
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
          enableOfflineQueue: true,
        });
      }
      break;
    }

    case "redis-ioredis": {
      if (config.useRedisCluster) {
        console.log("Connecting to Redis Cluster using ioredis");

        clientInstance = new Redis.Cluster(
          config.redisClusterNodes.map((node) => ({
            host: node.host,
            port: node.port,
          })),
          {
            redisOptions: {
              db: config.redisDb,
              connectTimeout: 5000,
              maxRetriesPerRequest: 3,
              enableOfflineQueue: true,
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

        clientInstance = new Redis({
          host: config.redisHost,
          port: config.redisPort,
          db: config.redisDb,
          connectTimeout: 5000,
          maxRetriesPerRequest: 3,
          enableOfflineQueue: true,
        });
      }
      break;
    }

    case "redis-node": {
      if (config.useRedisCluster) {
        console.log(
          "Redis Node client does not support cluster mode in rate-limiter-flexible"
        );
        throw new Error(
          "Cluster mode not supported with redis-node client in rate-limiter-flexible"
        );
      } else {
        console.log(
          `Connecting to Redis at ${config.redisHost}:${config.redisPort} using node-redis`
        );

        const url = `redis://${config.redisHost}:${config.redisPort}/${
          config.redisDb || 0
        }`;

        clientInstance = Redis.createClient({
          url,
          socket: {
            connectTimeout: 5000,
          },
        });

        await clientInstance.connect();
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
      await clientInstance.disconnect();
    } else if (
      clientInstance instanceof Redis ||
      clientInstance instanceof Redis.Cluster ||
      clientInstance instanceof Valkey.Valkey ||
      clientInstance instanceof Valkey.Cluster
    ) {
      await clientInstance.quit();
    } else if (config.mode === "redis-node" && clientInstance.quit) {
      // For node-redis client
      await clientInstance.quit();
    } else if (typeof clientInstance.disconnect === "function") {
      await clientInstance.disconnect();
    }
  } catch (err) {
    console.error("Error closing client:", err);
  } finally {
    clientInstance = null;
  }
}
