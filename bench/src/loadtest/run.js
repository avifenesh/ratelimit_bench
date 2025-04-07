/**
 * Advanced Load Testing Client for Rate Limiter Benchmark
 * 
 * This script simulates real-world traffic patterns with configurable:
 * - Concurrency levels
 * - Request types (light/heavy)
 * - Test durations
 * - Realistic browser-like behavior with randomized delays
 */

const axios = require('axios');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { Worker, isMainThread, parentPort, workerData } = require('worker_threads');

// Configuration from environment variables
const TARGET_URL = process.env.TARGET_URL || 'http://localhost:3000/api/light';
const CONCURRENCY = parseInt(process.env.CONCURRENCY || '50');
const DURATION_SECONDS = parseInt(process.env.DURATION || '30');
const REQUEST_TYPE = process.env.REQUEST_TYPE || 'light';
const SAVE_RESULTS = process.env.SAVE_RESULTS !== 'false';
const RESULT_DIR = process.env.RESULT_DIR || path.join(process.cwd(), 'results');
const RUN_ID = process.env.RUN_ID || new Date().toISOString().replace(/[:.]/g, '-');

// Advanced configuration for realistic browser-like behavior
const MIN_THINK_TIME_MS = 100;  // Minimum delay between requests for a single virtual user
const MAX_THINK_TIME_MS = 500;  // Maximum delay between requests for a single virtual user
const RAMP_UP_SECONDS = 5;      // Time to ramp up to full concurrency
const TIMEOUT_MS = 5000;        // Request timeout
const NUM_WORKERS = Math.min(CONCURRENCY, os.cpus().length);

// Statistics to track
const stats = {
  totalRequests: 0,
  successRequests: 0,
  failedRequests: 0,
  rateLimited: 0,
  errors: 0,
  startTime: 0,
  endTime: 0,
  requestTimes: [],
  responseStatusCodes: {},
  responseTimeHistogram: {
    '<10ms': 0,
    '10-50ms': 0,
    '50-100ms': 0,
    '100-250ms': 0,
    '250-500ms': 0,
    '500-1000ms': 0,
    '1s-2s': 0,
    '>2s': 0
  }
};

// Helper functions
const randomBetween = (min, max) => Math.floor(Math.random() * (max - min + 1) + min);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const getTimestampMs = () => new Date().getTime();

// Worker implementation (runs in worker threads)
if (!isMainThread) {
  const { id, targetUrl, concurrencyPerWorker, durationMs, requestType } = workerData;
  
  const workerStats = {
    totalRequests: 0,
    successRequests: 0,
    failedRequests: 0,
    rateLimited: 0,
    errors: 0,
    requestTimes: [],
    responseStatusCodes: {}
  };
  
  // Create headers with unique user IDs for this worker's virtual users
  const createHeaders = (userId) => ({
    'User-ID': `user-${id}-${userId}`,
    'Content-Type': 'application/json',
    'X-Request-Type': requestType
  });
  
  // Make a single request and record stats
  const makeRequest = async (userId) => {
    const startTime = getTimestampMs();
    let endTime;
    
    try {
      const response = await axios.get(targetUrl, {
        headers: createHeaders(userId),
        timeout: TIMEOUT_MS
      });
      
      endTime = getTimestampMs();
      workerStats.totalRequests++;
      
      // Record status code
      const statusCode = response.status;
      workerStats.responseStatusCodes[statusCode] = 
        (workerStats.responseStatusCodes[statusCode] || 0) + 1;
      
      if (statusCode >= 200 && statusCode < 300) {
        workerStats.successRequests++;
      } else if (statusCode === 429) {
        workerStats.rateLimited++;
      } else {
        workerStats.failedRequests++;
      }
      
      // Record response time
      workerStats.requestTimes.push(endTime - startTime);
      
      return true;
    } catch (error) {
      endTime = getTimestampMs();
      workerStats.totalRequests++;
      
      if (error.response) {
        // The request was made and the server responded with a status code
        // that falls out of the range of 2xx
        const statusCode = error.response.status;
        workerStats.responseStatusCodes[statusCode] = 
          (workerStats.responseStatusCodes[statusCode] || 0) + 1;
        
        if (statusCode === 429) {
          workerStats.rateLimited++;
        } else {
          workerStats.failedRequests++;
        }
      } else if (error.request) {
        // The request was made but no response was received
        workerStats.errors++;
        workerStats.responseStatusCodes['timeout'] = 
          (workerStats.responseStatusCodes['timeout'] || 0) + 1;
      } else {
        // Something happened in setting up the request that triggered an Error
        workerStats.errors++;
        workerStats.responseStatusCodes['error'] = 
          (workerStats.responseStatusCodes['error'] || 0) + 1;
      }
      
      // Record response time even for errors
      workerStats.requestTimes.push(endTime - startTime);
      
      return false;
    }
  };
  
  // Simulate a virtual user sending requests with thinking time
  const simulateUser = async (userId, endTime) => {
    while (getTimestampMs() < endTime) {
      await makeRequest(userId);
      
      // Add random "think time" between requests to simulate user behavior
      const thinkTime = randomBetween(MIN_THINK_TIME_MS, MAX_THINK_TIME_MS);
      await sleep(thinkTime);
    }
  };
  
  // Start the load test for this worker
  const runWorkerLoadTest = async () => {
    const endTime = getTimestampMs() + durationMs;
    const users = [];
    
    // Gradually ramp up users
    const rampUpTimePerUser = (RAMP_UP_SECONDS * 1000) / concurrencyPerWorker;
    
    for (let i = 0; i < concurrencyPerWorker; i++) {
      const userId = i;
      users.push(simulateUser(userId, endTime));
      
      // Stagger user startup during ramp-up period
      if (i < concurrencyPerWorker - 1) {
        await sleep(rampUpTimePerUser);
      }
    }
    
    // Wait for all users to complete
    await Promise.all(users);
    
    // Send results back to main thread
    parentPort.postMessage(workerStats);
  };
  
  // Run the worker
  runWorkerLoadTest().catch(err => {
    console.error(`Worker ${id} error:`, err);
    process.exit(1);
  });
}
// Main thread implementation
else {
  // Function to categorize a response time into a histogram bucket
  const categorizeResponseTime = (timeMs) => {
    if (timeMs < 10) return '<10ms';
    if (timeMs < 50) return '10-50ms';
    if (timeMs < 100) return '50-100ms';
    if (timeMs < 250) return '100-250ms';
    if (timeMs < 500) return '250-500ms';
    if (timeMs < 1000) return '500-1000ms';
    if (timeMs < 2000) return '1s-2s';
    return '>2s';
  };
  
  // Merge stats from all workers
  const mergeStats = (workerStats) => {
    stats.totalRequests += workerStats.totalRequests;
    stats.successRequests += workerStats.successRequests;
    stats.failedRequests += workerStats.failedRequests;
    stats.rateLimited += workerStats.rateLimited;
    stats.errors += workerStats.errors;
    stats.requestTimes = stats.requestTimes.concat(workerStats.requestTimes);
    
    // Merge status codes
    for (const [code, count] of Object.entries(workerStats.responseStatusCodes)) {
      stats.responseStatusCodes[code] = (stats.responseStatusCodes[code] || 0) + count;
    }
  };
  
  // Calculate final statistics
  const calculateFinalStats = () => {
    const totalDurationMs = stats.endTime - stats.startTime;
    const requestsPerSecond = stats.totalRequests / (totalDurationMs / 1000);
    
    // Calculate min, max, average and percentiles
    let minResponseTime = Number.MAX_SAFE_INTEGER;
    let maxResponseTime = 0;
    let totalResponseTime = 0;
    
    // Sort request times for percentile calculations
    stats.requestTimes.sort((a, b) => a - b);
    
    // Calculate min, max, total for average
    for (const time of stats.requestTimes) {
      minResponseTime = Math.min(minResponseTime, time);
      maxResponseTime = Math.max(maxResponseTime, time);
      totalResponseTime += time;
      
      // Update histogram
      const category = categorizeResponseTime(time);
      stats.responseTimeHistogram[category]++;
    }
    
    const avgResponseTime = totalResponseTime / stats.requestTimes.length;
    
    // Calculate percentiles
    const p50Index = Math.floor(stats.requestTimes.length * 0.5);
    const p90Index = Math.floor(stats.requestTimes.length * 0.9);
    const p95Index = Math.floor(stats.requestTimes.length * 0.95);
    const p99Index = Math.floor(stats.requestTimes.length * 0.99);
    
    const p50 = stats.requestTimes[p50Index];
    const p90 = stats.requestTimes[p90Index];
    const p95 = stats.requestTimes[p95Index];
    const p99 = stats.requestTimes[p99Index];
    
    return {
      concurrency: CONCURRENCY,
      totalRequests: stats.totalRequests,
      duration: totalDurationMs / 1000,
      requestsPerSecond,
      successRate: (stats.successRequests / stats.totalRequests) * 100,
      rateLimitedRate: (stats.rateLimited / stats.totalRequests) * 100,
      errorRate: ((stats.failedRequests + stats.errors) / stats.totalRequests) * 100,
      responseTimes: {
        min: minResponseTime,
        max: maxResponseTime,
        avg: avgResponseTime,
        p50,
        p90,
        p95,
        p99
      },
      responseTimeHistogram: stats.responseTimeHistogram,
      statusCodes: stats.responseStatusCodes
    };
  };
  
  // Save results to a file
  const saveResults = (finalStats) => {
    if (!SAVE_RESULTS) return;
    
    try {
      // Create results directory if it doesn't exist
      if (!fs.existsSync(RESULT_DIR)) {
        fs.mkdirSync(RESULT_DIR, { recursive: true });
      }
      
      // Create a results subdirectory for this run
      const runDir = path.join(RESULT_DIR, RUN_ID);
      if (!fs.existsSync(runDir)) {
        fs.mkdirSync(runDir, { recursive: true });
      }
      
      // Save detailed JSON results
      const jsonFile = path.join(runDir, `${REQUEST_TYPE}_${CONCURRENCY}_${DURATION_SECONDS}s.json`);
      fs.writeFileSync(jsonFile, JSON.stringify(finalStats, null, 2));
      
      // Create a summary markdown file
      const summaryFile = path.join(runDir, 'summary.md');
      const hasExistingSummary = fs.existsSync(summaryFile);
      
      const summaryContent = `## ${REQUEST_TYPE.toUpperCase()} Test - ${CONCURRENCY} concurrent users - ${DURATION_SECONDS}s\n\n` +
        `- **Success Rate**: ${finalStats.successRate.toFixed(2)}%\n` +
        `- **Requests/second**: ${finalStats.requestsPerSecond.toFixed(2)}\n` +
        `- **Rate Limited**: ${finalStats.rateLimitedRate.toFixed(2)}%\n` +
        `- **Average Response Time**: ${finalStats.responseTimes.avg.toFixed(2)}ms\n` +
        `- **P95 Response Time**: ${finalStats.responseTimes.p95.toFixed(2)}ms\n` +
        `- **P99 Response Time**: ${finalStats.responseTimes.p99.toFixed(2)}ms\n\n`;
      
      if (hasExistingSummary) {
        fs.appendFileSync(summaryFile, `\n\n${summaryContent}`);
      } else {
        fs.writeFileSync(summaryFile, `# Rate Limiter Benchmark Results - ${new Date().toISOString()}\n\n${summaryContent}`);
      }
      
      console.log(`Results saved to ${runDir}`);
    } catch (error) {
      console.error('Error saving results:', error);
    }
  };
  
  // Main function to run the load test
  const runLoadTest = async () => {
    console.log(`Starting load test with ${CONCURRENCY} concurrent users for ${DURATION_SECONDS} seconds`);
    console.log(`URL: ${TARGET_URL}`);
    console.log(`Using ${NUM_WORKERS} worker threads`);
    
    stats.startTime = getTimestampMs();
    
    const workers = [];
    const concurrencyPerWorker = Math.ceil(CONCURRENCY / NUM_WORKERS);
    
    // Create and start all workers
    for (let i = 0; i < NUM_WORKERS; i++) {
      const worker = new Worker(__filename, {
        workerData: {
          id: i,
          targetUrl: TARGET_URL,
          concurrencyPerWorker,
          durationMs: DURATION_SECONDS * 1000,
          requestType: REQUEST_TYPE
        }
      });
      
      worker.on('message', mergeStats);
      
      worker.on('error', (err) => {
        console.error(`Worker ${i} error:`, err);
      });
      
      worker.on('exit', (code) => {
        if (code !== 0) {
          console.error(`Worker ${i} stopped with exit code ${code}`);
        }
      });
      
      workers.push(worker);
    }
    
    // Wait for all workers to finish
    await Promise.all(workers.map(worker => {
      return new Promise((resolve) => {
        worker.on('exit', resolve);
      });
    }));
    
    stats.endTime = getTimestampMs();
    
    // Calculate and print final stats
    const finalStats = calculateFinalStats();
    
    console.log('\n======= TEST RESULTS =======');
    console.log(`Concurrency: ${CONCURRENCY} users`);
    console.log(`Duration: ${(finalStats.duration).toFixed(2)}s`);
    console.log(`Request Type: ${REQUEST_TYPE}`);
    console.log(`Total Requests: ${finalStats.totalRequests}`);
    console.log(`Requests/second: ${finalStats.requestsPerSecond.toFixed(2)}`);
    console.log(`Success Rate: ${finalStats.successRate.toFixed(2)}%`);
    console.log(`Rate Limited: ${finalStats.rateLimitedRate.toFixed(2)}%`);
    console.log('\nResponse Time (ms):');
    console.log(`  Min: ${finalStats.responseTimes.min}`);
    console.log(`  Avg: ${finalStats.responseTimes.avg.toFixed(2)}`);
    console.log(`  Max: ${finalStats.responseTimes.max}`);
    console.log(`  P50: ${finalStats.responseTimes.p50}`);
    console.log(`  P90: ${finalStats.responseTimes.p90}`);
    console.log(`  P95: ${finalStats.responseTimes.p95}`);
    console.log(`  P99: ${finalStats.responseTimes.p99}`);
    
    console.log('\nResponse Status Codes:');
    for (const [code, count] of Object.entries(finalStats.statusCodes)) {
      console.log(`  ${code}: ${count} (${((count / finalStats.totalRequests) * 100).toFixed(2)}%)`);
    }
    
    // Save results
    saveResults(finalStats);
  };
  
  // Run the test
  runLoadTest().catch(err => {
    console.error('Error running load test:', err);
    process.exit(1);
  });
}
