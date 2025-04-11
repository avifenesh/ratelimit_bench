/**
 * Client Factory
 * Creates appropriate Redis/Valkey clients based on configuration
 */

import * as ioredis from "ioredis";
import { Redis as Valkey, Cluster as ValkeyCluster } from "iovalkey";
import { GlideClient, GlideClusterClient, Logger } from "@valkey/valkey-glide";
import { getConfig } from "../config/index.js";

const config = getConfig();

// Define a common client type alias
type RateLimiterClient =
  | ioredis.Redis
  | ioredis.Cluster
  | Valkey
  | ValkeyCluster
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

      if (config.valkey.cluster) {
        console.log("Connecting to Valkey Cluster using valkey-glide client");

        // Configure cluster options with optimized settings
        clientInstance = await GlideClusterClient.createClient({
          addresses:
            config.valkey.clusterNodes?.map((node) => {
              const [host, portStr] = node.split(":");
              const port = parseInt(portStr, 10);
              return { host, port };
            }) || [],
          // Optimized settings for Valkey Cluster
          useTLS: false,
          requestTimeout: 3000,
          advancedConfiguration: {
            connectionTimeout: 1000,
          },
        });
      } else {
        console.log(
          `Connecting to Valkey at ${config.valkey.host}:${config.valkey.port} using valkey-glide client`
        );

        // Configure standalone options with optimized settings
        clientInstance = await GlideClient.createClient({
          addresses: [
            {
              host: config.valkey.host,
              port: config.valkey.port,
            },
          ],
          requestTimeout: 3000,
          advancedConfiguration: {
            connectionTimeout: 1000,
          },
        });
      }
      break;
    }

    case "valkey-io": {
      if (config.valkey.cluster) {
        console.log("Connecting to Valkey Cluster using iovalkey client");

        clientInstance = new ValkeyCluster(
          config.valkey.clusterNodes?.map((node) => {
            const [host, portStr] = node.split(":");
            const port = parseInt(portStr, 10);
            return { host, port };
          }) || [],
          {
            redisOptions: {
              connectTimeout: 5000,
              maxRetriesPerRequest: 3,
              offlineQueue: true,
            },
          }
        );
      } else {
        console.log(
          `Connecting to Valkey at ${config.valkey.host}:${config.valkey.port} using iovalkey client`
        );

        clientInstance = new Valkey({
          host: config.valkey.host,
          port: config.valkey.port,
          connectTimeout: 5000,
          maxRetriesPerRequest: 3,
          offlineQueue: true,
        });
      }
      break;
    }

    case "ioredis": {
      if (config.redis.cluster) {
        console.log("Connecting to Redis Cluster using ioredis");

        clientInstance = new ioredis.Cluster(
          config.redis.clusterNodes?.map((node) => {
            const [host, portStr] = node.split(":");
            const port = parseInt(portStr, 10);
            return { host, port };
          }) || [],
          {
            redisOptions: {
              connectTimeout: 1000,
              maxRetriesPerRequest: 3,
              offlineQueue: true,
            },
          }
        );
      } else {
        console.log(
          `Connecting to Redis at ${config.redis.host}:${config.redis.port} using ioredis`
        );

        clientInstance = new ioredis.Redis({
          host: config.redis.host,
          port: config.redis.port,
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
            host: config.valkey.host,
            port: config.valkey.port,
          },
        ],
        databaseId: 0,
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
      // For Valkey Glide clients, use close() method
      clientInstance.close();
    } else if (
      clientInstance instanceof ioredis.Redis ||
      clientInstance instanceof ioredis.Cluster ||
      clientInstance instanceof Valkey ||
      clientInstance instanceof ValkeyCluster
    ) {
      // For ioredis and iovalkey clients, use quit() for graceful disconnect
      await clientInstance.quit();
    }
  } catch (err) {
    console.error("Error closing client:", err);
  } finally {
    clientInstance = null;
  }
}
