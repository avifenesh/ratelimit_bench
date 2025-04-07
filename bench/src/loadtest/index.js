/**
 * Advanced Load Testing Script for Rate Limiter Benchmarking
 * 
 * Features:
 * - Supports both light and heavy request types to simulate real-world traffic
 * - Configurable concurrency levels
 * - Detailed metrics collection and reporting
 * - Realistic traffic patterns with randomized user IDs
 * - Proper error handling and reporting
 */

const axios = require('axios');
const { performance } = require('perf_hooks');
const fs = require('fs').promises;
const path = require('path');
const crypto = require('crypto');
const os = require('os');

// Configuration (from environment variables)
const TARGET_HOST = process.env.TARGET_HOST || 'localhost';
const TARGET_PORT = process.env.TARGET_PORT || 3000;
const REQUEST_TYPE = process.env.REQUEST_TYPE || 'light'; // 'light' or 'heavy'
const CONCURRENCY = parseInt(process.env.CONCURRENCY || '100');
const DURATION_SECONDS = parseInt(process.env.DURATION || '30');
const MODE = process.env.MODE || 'redis-ioredis';
const RUN_ID = process.env.RUN_ID || new Date().toISOString().replace(/[:.]/g, '-');

// URLs
const BASE_URL = `http://${TARGET_HOST}:${TARGET_PORT}`;
const LIGHT_URL = `${BASE_URL}/api/light`;
const HEAVY_URL = `${BASE_URL}/api/heavy`;
const HEALTH_URL = `${BASE_URL}/health`;
const METRICS_URL = `${BASE_URL}/metrics`;

// Result file path
const RESULTS_DIR = process.env.RESULTS_DIR || '/app/results';
const RESULT_FILE = path.join(RESULTS_DIR, `${REQUEST_TYPE}_c${CONCURRENCY}_${DURATION_SECONDS}s_${MODE}_${RUN_ID}.json`);

// Statistics tracking
const stats = {
  startTime: 0,
  endTime: 0,
  totalRequests: 0,
  successfulRequests: 0,
  failedRequests: 0,
  rateLimitedRequests: 0,
  responseTimes: [],
  errors: [],
  rps: 0,
};

// Generate a pool of user IDs to simulate different clients
const generateUserIds = (count) => {
  const userIds = [];
  for (let i = 0; i < count; i++) {
    userIds.push(crypto.randomBytes(8).toString('hex'));
  }
  return userIds;
};

// Create a pool of users (more users than concurrency to simulate a larger user base)
const userIds = generateUserIds(CONCURRENCY * 3);

// Logger function
const log = (message) => {
  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] ${message}`);
};

// Function to check if the server is healthy
const checkServerHealth = async () => {
  try {
    log('Checking server health...');
    const response = await axios.get(HEALTH_URL, { timeout: 5000 });
    
    if (response.status === 200 && response.data.status === 'ok') {
      log('Server is healthy');
      return true;
    } else {
      log(`Server health check failed: ${JSON.stringify(response.data)}`);
      return false;
    }
  } catch (error) {
    log(`Server health check error: ${error.message}`);
    return false;
  }
};

// Function to get server metrics
const getServerMetrics = async () => {
  try {
    log('Getting server metrics...');
    const response = await axios.get(METRICS_URL, { timeout: 5000 });
    return response.data;
  } catch (error) {
    log(`Failed to get server metrics: ${error.message}`);
    return null;
  }
};

// Function to make a single request
const makeRequest = async (userId) => {
  const url = REQUEST_TYPE === 'light' ? LIGHT_URL : HEAVY_URL;
  const startTime = performance.now();
  
  try {
    stats.totalRequests++;
    const response = await axios.get(url, {
      headers: {
        'User-Id': userId,
        'Content-Type': 'application/json',
      },
      timeout: 10000,
    });
    
    const endTime = performance.now();
    const responseTime = endTime - startTime;
    
    stats.responseTimes.push(responseTime);
    stats.successfulRequests++;
    
    return { success: true, responseTime };
  } catch (error) {
    const endTime = performance.now();
    const responseTime = endTime - startTime;
    
    // Check if rate limited
    if (error.response && error.response.status === 429) {
      stats.rateLimitedRequests++;
      return { success: false, rateLimit: true, responseTime };
    }
    
    stats.failedRequests++;
    stats.errors.push({
      url,
      statusCode: error.response?.status || 'unknown',
      message: error.message,
      timestamp: new Date().toISOString(),
    });
    
    return { success: false, error: error.message, responseTime };
  }
};

// Function to run concurrent requests
const runConcurrentRequests = async () => {
  const activeWorkers = new Set();
  const startTime = performance.now();
  stats.startTime = Date.now();
  
  log(`Starting load test with ${CONCURRENCY} concurrent users for ${DURATION_SECONDS} seconds`);
  log(`Request type: ${REQUEST_TYPE}`);
  
  // Function to simulate a single user making requests
  const userWorker = async (userId) => {
    while (performance.now() - startTime < DURATION_SECONDS * 1000) {
      await makeRequest(userId);
      
      // Add some randomization in request timing to make it more realistic
      const delay = Math.random() * 100;
      await new Promise(resolve => setTimeout(resolve, delay));
    }
    activeWorkers.delete(userId);
  };
  
  // Start the worker processes for each concurrent user
  for (let i = 0; i < CONCURRENCY; i++) {
    const userId = userIds[i % userIds.length];
    activeWorkers.add(userId);
    userWorker(userId).catch(error => {
      log(`Worker error: ${error.message}`);
      activeWorkers.delete(userId);
    });
  }
  
  // Wait for all workers to complete or timeout
  const checkInterval = setInterval(() => {
    const elapsedTime = performance.now() - startTime;
    
    if (elapsedTime >= DURATION_SECONDS * 1000) {
      clearInterval(checkInterval);
      
      if (activeWorkers.size > 0) {
        log(`Test duration complete. ${activeWorkers.size} workers still running, they will complete their current request.`);
      }
    }
  }, 1000);
  
  // Wait until all workers finish
  while (activeWorkers.size > 0) {
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  
  stats.endTime = Date.now();
  
  // Calculate statistics
  const totalTimeSeconds = (stats.endTime - stats.startTime) / 1000;
  stats.rps = stats.totalRequests / totalTimeSeconds;
  
  log(`Load test completed in ${totalTimeSeconds.toFixed(2)} seconds`);
  log(`Total requests: ${stats.totalRequests}`);
  log(`Successful requests: ${stats.successfulRequests}`);
  log(`Failed requests: ${stats.failedRequests}`);
  log(`Rate limited requests: ${stats.rateLimitedRequests}`);
  log(`Requests per second: ${stats.rps.toFixed(2)}`);
};

// Function to calculate percentiles
const calculatePercentile = (values, percentile) => {
  if (values.length === 0) return 0;
  
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.ceil((percentile / 100) * sorted.length) - 1;
  return sorted[index];
};

// Function to generate results
const generateResults = async () => {
  // Sort response times for percentile calculations
  const sortedTimes = [...stats.responseTimes].sort((a, b) => a - b);
  
  // Calculate percentiles and stats
  const results = {
    testConfig: {
      requestType: REQUEST_TYPE,
      concurrency: CONCURRENCY,
      durationSeconds: DURATION_SECONDS,
      mode: MODE,
      timestamp: new Date().toISOString(),
      runId: RUN_ID,
      host: TARGET_HOST,
      port: TARGET_PORT,
    },
    summary: {
      totalRequests: stats.totalRequests,
      successfulRequests: stats.successfulRequests,
      failedRequests: stats.failedRequests,
      rateLimitedRequests: stats.rateLimitedRequests,
      durationSeconds: (stats.endTime - stats.startTime) / 1000,
      requestsPerSecond: stats.rps,
      successRate: stats.totalRequests > 0 
        ? (stats.successfulRequests / stats.totalRequests) * 100 
        : 0,
      rateLimitedRate: stats.totalRequests > 0 
        ? (stats.rateLimitedRequests / stats.totalRequests) * 100 
        : 0,
    },
    responseTimes: {
      min: sortedTimes.length > 0 ? sortedTimes[0] : 0,
      max: sortedTimes.length > 0 ? sortedTimes[sortedTimes.length - 1] : 0,
      avg: sortedTimes.length > 0 
        ? sortedTimes.reduce((a, b) => a + b, 0) / sortedTimes.length 
        : 0,
      p50: calculatePercentile(sortedTimes, 50),
      p75: calculatePercentile(sortedTimes, 75),
      p90: calculatePercentile(sortedTimes, 90),
      p95: calculatePercentile(sortedTimes, 95),
      p99: calculatePercentile(sortedTimes, 99),
    },
    errors: stats.errors.slice(0, 10), // Include only the first 10 errors
    serverMetrics: await getServerMetrics(),
  };
  
  // Create directory if it doesn't exist
  await fs.mkdir(RESULTS_DIR, { recursive: true });
  
  // Write results to file
  await fs.writeFile(RESULT_FILE, JSON.stringify(results, null, 2));
  log(`Results written to ${RESULT_FILE}`);
  
  // Also print results summary to console
  console.log('\n========== TEST RESULTS ==========');
  console.log(`Test: ${REQUEST_TYPE.toUpperCase()} requests with ${CONCURRENCY} concurrent users for ${DURATION_SECONDS} seconds`);
  console.log(`Total Requests: ${results.summary.totalRequests}`);
  console.log(`Success Rate: ${results.summary.successRate.toFixed(2)}%`);
  console.log(`Rate Limited: ${results.summary.rateLimitedRate.toFixed(2)}%`);
  console.log(`Requests/second: ${results.summary.requestsPerSecond.toFixed(2)}`);
  console.log(`Avg Response Time: ${results.responseTimes.avg.toFixed(2)} ms`);
  console.log(`P95 Response Time: ${results.responseTimes.p95.toFixed(2)} ms`);
  console.log('====================================\n');
  
  return results;
};

// Main function
const main = async () => {
  try {
    log('Starting load test script');
    
    // Check if server is ready
    const isHealthy = await checkServerHealth();
    if (!isHealthy) {
      log('Server is not healthy, aborting load test');
      process.exit(1);
    }
    
    // Run the load test
    await runConcurrentRequests();
    
    // Generate and save results
    await generateResults();
    
    log('Load test completed successfully');
    process.exit(0);
  } catch (error) {
    log(`Load test failed: ${error.message}`);
    log(error.stack);
    process.exit(1);
  }
};

// Run the main function
main().catch(error => {
  console.error('Unhandled error:', error);
  process.exit(1);
});
