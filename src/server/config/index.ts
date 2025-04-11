/**
 * Server configuration
 * Loads and validates environment variables
 */

interface ClusterNode {
    host: string;
    port: number;
}

export interface Config {
    // Server settings
    port: number;
    logLevel: string;

    // Redis connection
    redisHost: string;
    redisPort: number;
    redisDb?: number;

    // Valkey connection
    valkeyHost: string;
    valkeyPort: number;
    valkeyDb?: number;

    // Redis/Valkey Cluster configurations
    useRedisCluster: boolean;
    useValkeyCluster: boolean;
    redisClusterNodes: ClusterNode[];
    valkeyClusterNodes: ClusterNode[];

    // Rate limiter options
    mode: string;
    rateLimit: number;
    blockDuration: number;
    duration: number;

    // Benchmark settings
    benchmark: {
        shortDuration: number;  // 30s
        longDuration: number;   // 2min
        concurrencyLevels: number[];
        scenarios: string[];
    };
}

// Parse JSON cluster nodes from environment variable
function parseClusterNodes(envVar: string | undefined, defaultNodes: ClusterNode[]): ClusterNode[] {
    if (!envVar) return defaultNodes;
    try {
        return JSON.parse(envVar) as ClusterNode[];
    } catch (e) {
        console.error('Error parsing cluster nodes configuration:', e);
        return defaultNodes;
    }
}

// Environment configuration with defaults
const config: Config = {
    // Server settings
    port: parseInt(process.env.PORT || '3000', 10),
    logLevel: process.env.LOG_LEVEL || 'info',

    // Redis connection
    redisHost: process.env.REDIS_HOST || 'localhost',
    redisPort: parseInt(process.env.REDIS_PORT || '6379', 10),
    redisDb: process.env.REDIS_DB ? parseInt(process.env.REDIS_DB, 10) : 0,

    // Valkey connection
    valkeyHost: process.env.VALKEY_HOST || 'localhost',
    valkeyPort: parseInt(process.env.VALKEY_PORT || '6380', 10),
    valkeyDb: process.env.VALKEY_DB ? parseInt(process.env.VALKEY_DB, 10) : 0,

    // Redis/Valkey Cluster configurations
    useRedisCluster: process.env.USE_REDIS_CLUSTER === 'true',
    useValkeyCluster: process.env.USE_VALKEY_CLUSTER === 'true',

    // Cluster nodes configuration
    redisClusterNodes: parseClusterNodes(process.env.REDIS_CLUSTER_NODES, [
        { host: 'redis-node1', port: 6379 },
        { host: 'redis-node2', port: 6379 },
        { host: 'redis-node3', port: 6379 },
        { host: 'redis-node4', port: 6379 },
        { host: 'redis-node5', port: 6379 },
        { host: 'redis-node6', port: 6379 }
    ]),

    // Valkey cluster nodes configuration (can be different from Redis)
    valkeyClusterNodes: parseClusterNodes(process.env.VALKEY_CLUSTER_NODES, [
        { host: 'valkey-node1', port: 8080 },
        { host: 'valkey-node2', port: 8080 },
        { host: 'valkey-node3', port: 8080 },
        { host: 'valkey-node4', port: 8080 },
        { host: 'valkey-node5', port: 8080 },
        { host: 'valkey-node6', port: 8080 }
    ]),

    // Rate limiter options
    mode: process.env.MODE || 'valkey-glide', // Default to valkey-glide (subtle prioritization)
    rateLimit: parseInt(process.env.RATE_LIMIT || '100', 10),
    blockDuration: parseInt(process.env.BLOCK_DURATION || '0', 10),
    duration: parseInt(process.env.DURATION || '60', 10),

    // Benchmark settings
    benchmark: {
        shortDuration: 30,  // 30 seconds
        longDuration: 120,  // 2 minutes
        concurrencyLevels: [10, 50, 100, 500, 1000],
        scenarios: ['light', 'heavy']
    }
};

export default config;

