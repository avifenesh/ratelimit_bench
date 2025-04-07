/**
 * Simple Node.js load testing script as alternative to k6
 */
const http = require('http');
const fs = require('fs');
const { performance } = require('perf_hooks');
const { Worker, isMainThread, parentPort, workerData } = require('worker_threads');
const os = require('os');

// Parse command line arguments
const args = process.argv.slice(2);
let url = 'http://localhost:3000/api/light';
let heavyUrl = 'http://localhost:3000/api/heavy';
let duration = 120; // default 120 seconds
let concurrency = 50; // default 50 concurrent users
let outputFile = './results.json';

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--url' && args[i + 1]) {
    url = args[i + 1];
  } else if (args[i] === '--heavy-url' && args[i + 1]) {
    heavyUrl = args[i + 1];
  } else if (args[i] === '--duration' && args[i + 1]) {
    duration = parseInt(args[i + 1], 10);
  } else if (args[i] === '--concurrency' && args[i + 1]) {
    concurrency = parseInt(args[i + 1], 10);
  } else if (args[i] === '--output' && args[i + 1]) {
    outputFile = args[i + 1];
  }
}

// Constants
const NUM_WORKERS = Math.min(os.cpus().length, concurrency);
const USERS_PER_WORKER = Math.ceil(concurrency / NUM_WORKERS);

if (isMainThread) {
  console.log(`Starting load test with ${concurrency} concurrent users for ${duration} seconds`);
  console.log(`Light URL: ${url}`);
  console.log(`Heavy URL: ${heavyUrl}`);
  console.log(`Using ${NUM_WORKERS} worker threads`);

  // Results collection
  const results = {
    totalRequests: 0,
    successfulRequests: 0,
    failedRequests: 0,
    blockedRequests: 0,
    lightRequests: 0,
    heavyRequests: 0,
    tps: 0,
    rps: 0,
    testDuration: duration,
    concurrency,
    latencies: [],
    lightLatencies: [],
    heavyLatencies: [],
    startTime: performance.now(),
    endTime: 0,
    errors: {},
    avgLatency: 0,
    p50Latency: 0,
    p95Latency: 0,
    p99Latency: 0,
    successRate: 0,
    blocks: 0
  };

  const workers = [];

  // Create workers
  for (let i = 0; i < NUM_WORKERS; i++) {
    const worker = new Worker(__filename, {
      workerData: {
        workerId: i,
        lightUrl: url,
        heavyUrl,
        duration,
        usersPerWorker: USERS_PER_WORKER
      }
    });

    workers.push(worker);

    worker.on('message', (workerResults) => {
      // Aggregate results from worker
      results.totalRequests += workerResults.totalRequests;
      results.successfulRequests += workerResults.successfulRequests;
      results.failedRequests += workerResults.failedRequests;
      results.blockedRequests += workerResults.blockedRequests;
      results.lightRequests += workerResults.lightRequests || 0;
      results.heavyRequests += workerResults.heavyRequests || 0;
      results.latencies = results.latencies.concat(workerResults.latencies);

      if (workerResults.lightLatencies) {
        results.lightLatencies = results.lightLatencies.concat(workerResults.lightLatencies);
      }

      if (workerResults.heavyLatencies) {
        results.heavyLatencies = results.heavyLatencies.concat(workerResults.heavyLatencies);
      }

      // Aggregate error counts
      for (const [code, count] of Object.entries(workerResults.errors)) {
        if (!results.errors[code]) {
          results.errors[code] = 0;
        }
        results.errors[code] += count;
      }
    });

    worker.on('error', (err) => {
      console.error(`Worker ${i} error:`, err);
    });

    worker.on('exit', (code) => {
      if (code !== 0) {
        console.error(`Worker ${i} exited with code ${code}`);
      }

      // Check if all workers have completed
      if (workers.every(w => w.threadId && !w.isRunning())) {
        // Calculate final results
        results.endTime = performance.now();
        const testDurationMs = results.endTime - results.startTime;

        // Calculate transactions per second
        results.tps = results.totalRequests / (testDurationMs / 1000);
        results.rps = results.successfulRequests / (testDurationMs / 1000);

        // Calculate latency statistics
        if (results.latencies.length > 0) {
          // Sort latencies for percentile calculations
          results.latencies.sort((a, b) => a - b);

          // Calculate average latency
          results.avgLatency = results.latencies.reduce((sum, val) => sum + val, 0) / results.latencies.length;

          // Calculate percentiles
          const p50Index = Math.floor(results.latencies.length * 0.5);
          const p95Index = Math.floor(results.latencies.length * 0.95);
          const p99Index = Math.floor(results.latencies.length * 0.99);

          results.p50Latency = results.latencies[p50Index];
          results.p95Latency = results.latencies[p95Index];
          results.p99Latency = results.latencies[p99Index];
        }

        // Calculate endpoint-specific latencies
        if (results.lightLatencies && results.lightLatencies.length > 0) {
          results.lightLatencies.sort((a, b) => a - b);
          const lightP95Index = Math.floor(results.lightLatencies.length * 0.95);
          results.avgLightLatency = results.lightLatencies.reduce((sum, val) => sum + val, 0) / results.lightLatencies.length;
          results.p95LightLatency = results.lightLatencies[lightP95Index];
        }

        if (results.heavyLatencies && results.heavyLatencies.length > 0) {
          results.heavyLatencies.sort((a, b) => a - b);
          const heavyP95Index = Math.floor(results.heavyLatencies.length * 0.95);
          results.avgHeavyLatency = results.heavyLatencies.reduce((sum, val) => sum + val, 0) / results.heavyLatencies.length;
          results.p95HeavyLatency = results.heavyLatencies[heavyP95Index];
        }

        // Calculate success rate
        results.successRate = (results.successfulRequests / results.totalRequests) * 100;
        results.blocks = results.blockedRequests;

        // Remove raw latency arrays to save space
        delete results.latencies;
        delete results.lightLatencies;
        delete results.heavyLatencies;

        // Print summary
        console.log(`
Load Test Results:
-----------------
Total Requests:     ${results.totalRequests}
  Light Requests:   ${results.lightRequests}
  Heavy Requests:   ${results.heavyRequests}
Successful:         ${results.successfulRequests}
Failed:             ${results.failedRequests}
Blocked:            ${results.blockedRequests}
Avg RPS:            ${results.rps.toFixed(2)}
Avg Latency:        ${results.avgLatency.toFixed(2)} ms
  Light Latency:    ${results.avgLightLatency?.toFixed(2) || 'N/A'} ms
  Heavy Latency:    ${results.avgHeavyLatency?.toFixed(2) || 'N/A'} ms
P95 Latency:        ${results.p95Latency.toFixed(2)} ms
  Light P95:        ${results.p95LightLatency?.toFixed(2) || 'N/A'} ms
  Heavy P95:        ${results.p95HeavyLatency?.toFixed(2) || 'N/A'} ms
Success Rate:       ${results.successRate.toFixed(2)}%
Test Duration:      ${(testDurationMs / 1000).toFixed(2)} seconds
`);

        // Save results
        fs.writeFileSync(outputFile, JSON.stringify(results, null, 2));
        console.log(`Results saved to ${outputFile}`);
      }
    });
  }

  // Start all workers
  workers.forEach(worker => worker.postMessage('start'));
} else {
  // Worker thread code
  const { workerId, lightUrl, heavyUrl, duration, usersPerWorker } = workerData;

  // Worker results
  const workerResults = {
    totalRequests: 0,
    successfulRequests: 0,
    failedRequests: 0,
    blockedRequests: 0,
    lightRequests: 0,
    heavyRequests: 0,
    latencies: [],
    lightLatencies: [],
    heavyLatencies: [],
    errors: {}
  };

  // Create users
  const users = [];
  for (let i = 0; i < usersPerWorker; i++) {
    users.push({
      id: `user-${workerId}-${i}`,
      running: false
    });
  }

  // Function to make a request
  async function makeRequest(userId, isLightRequest) {
    const targetUrl = isLightRequest ? lightUrl : heavyUrl;
    const startTime = performance.now();

    return new Promise((resolve) => {
      const req = http.request(targetUrl, {
        method: 'GET',
        headers: {
          'User-ID': userId
        }
      }, (res) => {
        const endTime = performance.now();
        const latency = endTime - startTime;

        workerResults.totalRequests++;
        workerResults.latencies.push(latency);

        if (isLightRequest) {
          workerResults.lightRequests++;
          workerResults.lightLatencies.push(latency);
        } else {
          workerResults.heavyRequests++;
          workerResults.heavyLatencies.push(latency);
        }

        res.on('end', () => {
          if (res.statusCode === 200) {
            workerResults.successfulRequests++;
          } else if (res.statusCode === 429) {
            workerResults.blockedRequests++;
          } else {
            workerResults.failedRequests++;

            // Count errors by status code
            const errorCode = res.statusCode.toString();
            if (!workerResults.errors[errorCode]) {
              workerResults.errors[errorCode] = 0;
            }
            workerResults.errors[errorCode]++;
          }

          resolve();
        });
      });

      req.on('error', () => {
        const endTime = performance.now();
        const latency = endTime - startTime;

        workerResults.totalRequests++;
        workerResults.failedRequests++;
        workerResults.latencies.push(latency);

        if (isLightRequest) {
          workerResults.lightLatencies.push(latency);
        } else {
          workerResults.heavyLatencies.push(latency);
        }

        // Count connection errors
        if (!workerResults.errors.connection) {
          workerResults.errors.connection = 0;
        }
        workerResults.errors.connection++;

        resolve();
      });

      req.end();
    });
  }

  // Function to run a user's requests
  async function runUser(user) {
    user.running = true;

    while (user.running) {
      // 70% chance of light request, 30% chance of heavy request
      const isLightRequest = Math.random() < 0.7;
      await makeRequest(user.id, isLightRequest);

      // Add small random delay between requests (50-200ms)
      // This helps prevent perfect synchronization between users
      await new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 150));
    }
  }

  // Wait for start message from main thread
  parentPort.once('message', async (message) => {
    if (message === 'start') {
      // Start all users
      const userPromises = users.map(user => runUser(user));

      // Set test duration
      setTimeout(() => {
        // Stop all users
        users.forEach(user => { user.running = false; });

        // Wait a bit to make sure all requests finish
        setTimeout(() => {
          // Send results back to main thread
          parentPort.postMessage(workerResults);
        }, 500);
      }, duration * 1000);

      // Wait for all users to finish
      await Promise.all(userPromises);
    }
  });
}
