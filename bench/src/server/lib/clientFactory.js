/**
 * Client Factory
 * Creates appropriate Redis/Valkey clients based on configuration
 */

const Redis = require('ioredis');
const redis = require('redis');
const Valkey = require('iovalkey');
const { GlideClient, Logger, GlideClusterClient } = require('@valkey/valkey-glide');
const config = require('../config');

/**
 * Creates an appropriate client for the selected mode
 * @returns {Promise<Object>} The connected client instance
 */
async function createClient() {
  let client;

  switch (config.mode) {
    case 'valkey-glide': {
      if (config.useValkeyCluster) {
        console.log('Connecting to Valkey Cluster using valkey-glide client');
        // Transform nodes array to format expected by GlideClient
        const addresses = config.valkeyClusterNodes.map(node => ({
          host: node.host,
          port: node.port
        }));

        client = await GlideClusterClient.createClient({
          addresses,
          useTLS: false,
          requestTimeout: 1000,
          // Enable cluster mode
          clientOptions: {
            enableClustering: true
          }
        });
        Logger.init('off');
      } else {
        console.log(`Connecting to Valkey at ${config.valkeyHost}:${config.valkeyPort} using valkey-glide client`);
        client = await GlideClient.createClient({
          addresses: [{ host: config.valkeyHost, port: config.valkeyPort }],
          useTLS: false,
          requestTimeout: 1000
        });
        Logger.init('off'); // Disable logging for GlideClient to avoid clutter
      }
      break;
    }

    case 'valkey-io': {
      if (config.useValkeyCluster) {
        console.log('Connecting to Valkey Cluster using iovalkey client');
        const clusterOptions = {
          enableOfflineQueue: false,
          maxRetriesPerRequest: 1,
          connectTimeout: 5000,
          redisOptions: {
            enableOfflineQueue: false,
            connectTimeout: 5000,
            maxRetriesPerRequest: 1
          }
        };

        // Create a cluster client with the nodes configuration
        client = new Valkey.Cluster(
          config.valkeyClusterNodes,
          clusterOptions
        );
      } else {
        console.log(`Connecting to Valkey at ${config.valkeyHost}:${config.valkeyPort} using iovalkey client`);
        client = new Valkey({
          port: config.valkeyPort,
          host: config.valkeyHost,
          enableOfflineQueue: false,
          maxRetriesPerRequest: 1,
          connectTimeout: 5000
        });
      }
      break;
    }

    case 'redis-ioredis': {
      if (config.useRedisCluster) {
        console.log('Connecting to Redis Cluster using ioredis');
        const clusterOptions = {
          enableReadyCheck: true,
          scaleReads: 'all', // Try to distribute reads across nodes
          maxRedirections: 3,
          retryDelayOnFailover: 100,
          retryDelayOnClusterDown: 100,
          enableOfflineQueue: false,
          redisOptions: {
            enableOfflineQueue: false,
            connectTimeout: 5000,
            maxRetriesPerRequest: 1
          }
        };

        client = new Redis.Cluster(
          config.clusterNodes,
          clusterOptions
        );
      } else {
        console.log(`Connecting to Redis at ${config.redisHost}:${config.redisPort} using ioredis`);
        client = new Redis({
          host: config.redisHost,
          port: config.redisPort,
          enableOfflineQueue: false,
          maxRetriesPerRequest: 1,
          connectTimeout: 5000
        });
      }
      break;
    }

    case 'redis-node': {
      if (config.useRedisCluster) {
        console.log('Connecting to Redis Cluster using node-redis');

        // Construct Redis URLs for each node
        const clusterUrls = config.clusterNodes.map(node =>
          `redis://${node.host}:${node.port}`
        );

        client = redis.createClient({
          url: clusterUrls[0], // Primary URL
          socket: {
            connectTimeout: 5000
          },
          cluster: {
            rootNodes: clusterUrls,
            minimizeConnections: false
          }
        });

        await client.connect();
      } else {
        console.log(`Connecting to Redis at ${config.redisHost}:${config.redisPort} using node-redis`);
        client = redis.createClient({
          url: `redis://${config.redisHost}:${config.redisPort}`,
          socket: {
            connectTimeout: 5000
          }
        });
        await client.connect();
      }
      break;
    }

    default: {
      console.log(`Unknown mode ${config.mode}, defaulting to valkey-glide standalone`);
      client = await GlideClient.createClient({
        addresses: [{ host: config.valkeyHost, port: config.valkeyPort }],
        useTLS: false,
        requestTimeout: 1000
      });
      Logger.init('off');
    }
  }

  return client;
}

/**
 * Closes the client connection gracefully based on client type
 * @param {Object} client - The client to close
 * @returns {Promise<void>}
 */
async function closeClient(client) {
  if (!client) return;

  try {
    if (config.mode === 'valkey-glide') {
      await client.close();
    } else if (config.mode === 'redis-node') {
      await client.quit();
    } else {
      // For ioredis and iovalkey
      await client.quit();
    }
  } catch (err) {
    console.error('Error closing client:', err);
  }
}

module.exports = {
  createClient,
  closeClient
};
