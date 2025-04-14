/**
 * Autocannon benchmark runner
 * Main entry point for running benchmarks against the API server
 */
import autocannon, { Instance } from "autocannon";
import { performance } from "perf_hooks";
import { writeFileSync } from "fs";
import { monitorResources } from "./monitor.js";

interface BenchmarkOptions {
  url: string;
  duration: number;
  connections: number;
  requestType: "light" | "heavy";
  outputFile?: string;
  rateLimiterType?: string;
}

// Main benchmark function
export async function runBenchmark(options: BenchmarkOptions): Promise<void> {
  const {
    url,
    duration,
    connections,
    requestType,
    outputFile,
    rateLimiterType,
  } = options;

  console.log(`Starting benchmark: ${rateLimiterType || "unknown"}`);
  console.log(`Target: ${url}`);
  console.log(
    `Configuration: ${connections} connections, ${duration}s duration, ${requestType} workload`
  );

  // Start resource monitoring
  const resourceMonitor = monitorResources();

  // Track rate limit hits with a local counter
  let rateLimitHits = 0;

  // Track start time
  const startTime = performance.now();

  // Return a promise that resolves when the benchmark is done
  return new Promise<void>((resolve, reject) => {
    // Create the benchmark instance using the callback style
    // This returns an Instance (not a Promise)
    const instance: Instance = autocannon(
      {
        url: `${url}/api?userId=user-${Math.floor(Math.random() * 1000)}`,
        connections,
        duration,
        headers: {
          Accept: "application/json",
        },
        requests: [
          {
            method: "GET",
          },
        ],
        // Set up client to track rate limit hits
        setupClient: (client) => {
          client.on("response", (statusCode, _resBytes) => {
            if (statusCode === 429) {
              rateLimitHits++;
              console.log(`Rate limit hit detected, status: ${statusCode}`);
            }
          });
        },
      },
      // Callback receives results when done
      (err, results) => {
        if (err) {
          console.error("Benchmark error:", err);
          reject(err);
          return;
        }

        try {
          // Stop resource monitoring
          const resourceStats = resourceMonitor.stop();

          // Calculate benchmark duration
          const endTime = performance.now();
          const actualDuration = (endTime - startTime) / 1000;

          // Process results
          const processedResults = {
            timestamp: new Date().toISOString(),
            implementation: rateLimiterType || "unknown",
            requestType,
            connections,
            duration: actualDuration,
            requests: {
              total: results.requests.total,
              average: results.requests.average,
              sent: results.requests.sent,
            },
            throughput: {
              average: results.throughput.average,
              mean: results.throughput.mean,
              stddev: results.throughput.stddev,
            },
            latency: {
              average: results.latency.average,
              mean: results.latency.mean,
              stddev: results.latency.stddev,
              p50: results.latency.p50,
              p75: results.latency.p75,
              p90: results.latency.p90,
              p97_5: results.latency.p97_5,
              p99: results.latency.p99,
              max: results.latency.max,
              min: results.latency.min,
            },
            errors: results.errors,
            timeouts: results.timeouts,
            non2xx: results.non2xx,

            // Use the local counter for rate limit hits
            rateLimitHits,

            // Resource usage
            resources: {
              cpu: resourceStats.cpu,
              memory: resourceStats.memory,
            },
          };

          // Output results
          console.log("\nBenchmark results:");
          console.log(
            `Requests/sec: ${Math.round(processedResults.requests.average)}`
          );
          console.log(`Latency avg: ${processedResults.latency.average} ms`);
          console.log(`Latency p97_5: ${processedResults.latency.p97_5} ms`);
          console.log(`Latency p99: ${processedResults.latency.p99} ms`);
          console.log(`Rate limit hits: ${processedResults.rateLimitHits}`);
          console.log(
            `CPU usage avg: ${
              Math.round(resourceStats.cpu.average * 100) / 100
            }%`
          );
          console.log(
            `Memory usage avg: ${Math.round(
              resourceStats.memory.average / (1024 * 1024)
            )} MB`
          );

          // Save results to file if specified
          if (outputFile) {
            writeFileSync(
              outputFile,
              JSON.stringify(processedResults, null, 2)
            );
            console.log(`Results saved to: ${outputFile}`);
          }

          resolve();
        } catch (error) {
          console.error("Error processing benchmark results:", error);
          reject(error);
        }
      }
    );

    // Track the instance with progress bar
    autocannon.track(instance, {
      renderProgressBar: true,
      renderLatencyTable: false,
    });
  });
}
