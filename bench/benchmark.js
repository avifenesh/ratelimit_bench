const {
  RateLimiterRedis,
  RateLimiterValkey,
  RateLimiterValkeyGlide
} = require('rate-limiter-flexible');
const Redis = require('ioredis');
const redis = require('redis');
const Valkey = require('iovalkey');
const { GlideClient } = require('@valkey/valkey-glide');
const microtime = require('microtime');
const pLimit = require('p-limit');
const chalk = require('chalk');

// Configuration
const ITERATIONS = 10000;
const CONCURRENCY = 100;
const KEYS_COUNT = 1000;
const POINTS_TO_CONSUME = 1;
const RATE_LIMIT = 100;
const DURATION = 10; // seconds

// Connect to Redis and Valkey
const redisClient = new Redis({
  port: 6379,
  host: '127.0.0.1',
  enableOfflineQueue: false
});

const redisNodeClient = redis.createClient({
  url: 'redis://127.0.0.1:6379',
  legacyMode: false
});

const valkeyClient = new Valkey({
  port: 8080,
  host: '127.0.0.1'
});

const valkeyGlideClient = await GlideClient.createClient({ addresses: [{ host: '127.0.0.1', port: 8080 }], useTLS: false });

// Rate limiters setup
const limiterRedisIoredis = new RateLimiterRedis({
  storeClient: redisClient,
  points: RATE_LIMIT,
  duration: DURATION,
  keyPrefix: 'benchmark:ioredis'
});

const limiterRedisNode = new RateLimiterRedis({
  storeClient: redisNodeClient,
  points: RATE_LIMIT,
  duration: DURATION,
  keyPrefix: 'benchmark:redis',
  useRedisPackage: true
});

const limiterValkey = new RateLimiterValkey({
  storeClient: valkeyClient,
  points: RATE_LIMIT,
  duration: DURATION,
  keyPrefix: 'benchmark:valkey'
});

const limiterValkeyGlide = new RateLimiterValkeyGlide({
  storeClient: valkeyGlideClient,
  points: RATE_LIMIT,
  duration: DURATION,
  keyPrefix: 'benchmark:valkeyglide'
});

// Generate keys
const generateKeys = (count) => {
  return Array.from({ length: count }, (_, i) => `user:${i % 1000}`);
};

// Run benchmark
async function runBenchmark(limiter, name) {
  console.log(chalk.blue(`\nStarting benchmark for ${name}...`));

  const keys = generateKeys(ITERATIONS);
  const limit = pLimit(CONCURRENCY);

  const startTime = microtime.now();

  const promises = keys.map((key, i) => {
    return limit(async () => {
      const start = microtime.now();
      try {
        await limiter.consume(key, POINTS_TO_CONSUME);
        const end = microtime.now();
        return { success: true, time: (end - start) / 1000 }; // Convert to ms
      } catch (err) {
        if (err instanceof Error) {
          console.error(`Error with ${name}:`, err);
          return { success: false, time: 0, error: err.message };
        }
        const end = microtime.now();
        return { success: false, time: (end - start) / 1000, rejected: true };
      }
    });
  });

  const allResults = await Promise.all(promises);
  const endTime = microtime.now();

  const successResults = allResults.filter(r => r.success);
  const totalTime = (endTime - startTime) / 1000; // Convert to ms
  const avgTime = successResults.reduce((sum, r) => sum + r.time, 0) / successResults.length;
  const maxTime = Math.max(...successResults.map(r => r.time));
  const minTime = Math.min(...successResults.map(r => r.time));

  // Calculate percentiles
  const sortedTimes = [...successResults.map(r => r.time)].sort((a, b) => a - b);
  const p50 = sortedTimes[Math.floor(sortedTimes.length * 0.5)];
  const p95 = sortedTimes[Math.floor(sortedTimes.length * 0.95)];
  const p99 = sortedTimes[Math.floor(sortedTimes.length * 0.99)];

  const throughput = (successResults.length / totalTime) * 1000; // Operations per second

  return {
    name,
    totalTime,
    operations: successResults.length,
    throughput: throughput.toFixed(2),
    avgTime: avgTime.toFixed(2),
    minTime: minTime.toFixed(2),
    maxTime: maxTime.toFixed(2),
    p50: p50.toFixed(2),
    p95: p95.toFixed(2),
    p99: p99.toFixed(2),
    rejections: allResults.filter(r => r.rejected).length,
    errors: allResults.filter(r => !r.success && !r.rejected).length
  };
}

// Print results
function printResults(results) {
  console.log(chalk.green('\n=== BENCHMARK RESULTS ==='));

  // Table header
  console.log(
    chalk.yellow('\nName'.padEnd(20)) +
    chalk.yellow('Ops/sec'.padEnd(12)) +
    chalk.yellow('Avg (ms)'.padEnd(12)) +
    chalk.yellow('Min (ms)'.padEnd(12)) +
    chalk.yellow('Max (ms)'.padEnd(12)) +
    chalk.yellow('p50 (ms)'.padEnd(12)) +
    chalk.yellow('p95 (ms)'.padEnd(12)) +
    chalk.yellow('p99 (ms)'.padEnd(12))
  );

  // Sort by throughput (highest first)
  results.sort((a, b) => parseFloat(b.throughput) - parseFloat(a.throughput));

  // Print each result
  results.forEach(result => {
    console.log(
      chalk.white(result.name.padEnd(20)) +
      chalk.cyan(result.throughput.padEnd(12)) +
      chalk.cyan(result.avgTime.padEnd(12)) +
      chalk.cyan(result.minTime.padEnd(12)) +
      chalk.cyan(result.maxTime.padEnd(12)) +
      chalk.cyan(result.p50.padEnd(12)) +
      chalk.cyan(result.p95.padEnd(12)) +
      chalk.cyan(result.p99.padEnd(12))
    );
  });
}

// Main function
async function main() {
  try {
    // Connect clients
    await redisNodeClient.connect();

    console.log(chalk.green('Starting benchmark with the following parameters:'));
    console.log(chalk.white(`- Iterations: ${ITERATIONS}`));
    console.log(chalk.white(`- Concurrency: ${CONCURRENCY}`));
    console.log(chalk.white(`- Unique keys: ${KEYS_COUNT}`));
    console.log(chalk.white(`- Points limit: ${RATE_LIMIT}`));
    console.log(chalk.white(`- Duration: ${DURATION} seconds`));

    // Flush databases
    await redisClient.flushall();
    await valkeyClient.flushall();

    // Run benchmarks
    const results = [];

    results.push(await runBenchmark(limiterRedisIoredis, 'Redis (ioredis)'));
    results.push(await runBenchmark(limiterRedisNode, 'Redis (node-redis)'));
    results.push(await runBenchmark(limiterValkey, 'Valkey (iovalkey)'));
    results.push(await runBenchmark(limiterValkeyGlide, 'Valkey (glide)'));

    // Print results
    printResults(results);

    // Clean up
    await redisClient.quit();
    await redisNodeClient.quit();
    await valkeyClient.disconnect();
    valkeyGlideClient.close();

    console.log(chalk.green('\nBenchmark completed successfully.'));
  } catch (error) {
    console.error(chalk.red('Error running benchmark:'), error);
  }
}

// Run the benchmark
main();
