/* eslint-disable @typescript-eslint/no-explicit-any */
import * as ioredis from "ioredis";
import { Redis as Valkey, Cluster as ValkeyCluster } from "iovalkey";
import { GlideClient, GlideClusterClient, Logger } from "@valkey/valkey-glide";
import { getConfig } from "../config/index.js";

const config = getConfig();

type RateLimiterClient =
  | ioredis.Redis
  | ioredis.Cluster
  | Valkey
  | ValkeyCluster
  | GlideClient
  | GlideClusterClient;

let clientInstance: RateLimiterClient | null = null;

export async function createClient(): Promise<RateLimiterClient> {
  if (clientInstance) {
    return clientInstance;
  }

  try {
    switch (config.mode) {
      case "valkey-glide": {
        // Turn off logging for performance optimization
        Logger.init("off");

        if (config.valkey.cluster) {
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
          clientInstance = new ValkeyCluster(
            config.valkey.clusterNodes?.map((node) => {
              const [host, portStr] = node.split(":");
              const port = parseInt(portStr, 10);
              return { host, port };
            }) || []
          );
        } else {
          clientInstance = new Valkey({
            host: config.valkey.host,
            port: config.valkey.port,
          });
        }
        break;
      }

      case "ioredis": {
        if (config.redis.cluster) {
          clientInstance = new ioredis.Cluster(
            config.redis.clusterNodes?.map((node) => {
              const [host, portStr] = node.split(":");
              const port = parseInt(portStr, 10);
              return { host, port };
            }) || []
          );
        } else {
          clientInstance = new ioredis.Redis({
            host: config.redis.host,
            port: config.redis.port,
          });
        }
        break;
      }

      default: {
        Logger.init("off");

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
    throw error; // Re-throw the error after logging
  }
}

/**
 * Returns the current client instance without creating a new one
 */
export function getClient(): RateLimiterClient | null {
  return clientInstance;
}

/**
 * Closes the client connection
 */
export async function closeClient(): Promise<void> {
  if (clientInstance) {
    try {
      if (typeof (clientInstance as any).close === "function") {
        await (clientInstance as any).close();
      } else if (typeof (clientInstance as any).quit === "function") {
        await (clientInstance as any).quit();
      } else if (typeof (clientInstance as any).disconnect === "function") {
        (clientInstance as any).disconnect();
      }
      clientInstance = null;
      console.log("Client connection closed.");
    } catch (err) {
      console.error("Error closing client connection:", err);
    }
  }
}
