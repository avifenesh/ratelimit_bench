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

  try {
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
            useTLS: false,
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
            useTLS: false,
          });
        }
        break;
      }

      case "iovalkey": {
        if (config.valkey.cluster) {
          console.log("Connecting to Valkey Cluster using iovalkey client");

          clientInstance = new ValkeyCluster(
            config.valkey.clusterNodes?.map((node) => {
              const [host, portStr] = node.split(":");
              const port = parseInt(portStr, 10);
              return { host, port };
            }) || []
          );
        } else {
          console.log(
            `Connecting to Valkey at ${config.valkey.host}:${config.valkey.port} using iovalkey client`
          );

          clientInstance = new Valkey({
            host: config.valkey.host,
            port: config.valkey.port,
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
            }) || []
          );
        } else {
          console.log(
            `Connecting to Redis at ${config.redis.host}:${config.redis.port} using ioredis`
          );

          clientInstance = new ioredis.Redis({
            host: config.redis.host,
            port: config.redis.port,
          });
        }
        break;
      }

      default: {
        console.error(
          `Unknown mode "${config.mode}", defaulting to valkey-glide standalone. Valid modes are: valkey-glide, iovalkey, ioredis`
        );
        Logger.init("off");

        console.log(
          `Attempting to connect to ${config.valkey.host}:${config.valkey.port}`
        );
        clientInstance = await GlideClient.createClient({
          addresses: [
            {
              host: config.valkey.host,
              port: config.valkey.port,
            },
          ],
          useTLS: false,
        });
      }
    }

    return clientInstance;
  } catch (error) {
    console.error("Failed to create client:", error);

    console.error(`
    Connection troubleshooting tips:
    1. Ensure Valkey/Redis server is running at the configured address
    2. Check firewall settings allow connections to port ${
      config.mode.includes("valkey") ? config.valkey.port : config.redis.port
    }
    3. Verify Docker network configuration if running in containers
    4. Check that the mode '${
      config.mode
    }' is correctly spelled in your configuration
    `);

    throw error;
  }
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
      clientInstance instanceof ValkeyCluster
    ) {
      await clientInstance.quit();
    }
  } catch (err) {
    console.error("Error closing client:", err);
  } finally {
    clientInstance = null;
  }
}
