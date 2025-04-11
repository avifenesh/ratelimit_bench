/**
 * Autocannon benchmark runner
 * Main entry point for running benchmarks against the API server
 */
import autocannon from "autocannon";
import type { Result } from "autocannon";
import { ResourceMonitor } from "./monitor.js";
import { processResults, saveResults } from "./results.js";

/**
 * Run a benchmark using autocannon
 */
export async function runBenchmark(options: {
  url: string;
  duration: number;
  connections: number;
  scenario: "light" | "heavy";
  mode: string;
  useCluster: boolean;
  outputFile?: string;
}): Promise<void> {
  console.log(`Starting benchmark against ${options.url}`);
  console.log(
    `Duration: ${options.duration}s, Connections: ${options.connections}, Mode: ${options.mode}`
  );

  // Start resource monitoring
  const monitor = new ResourceMonitor(1000); // 1 second interval
  monitor.start();

  // Create an instance of autocannon using the callback style API which returns Instance directly
  const instance = autocannon(
    {
      url: options.url,
      connections: options.connections,
      duration: options.duration,
      headers: {
        "User-Agent": "autocannon",
      },
    },
    (err) => {
      // This callback will be called when the benchmark is complete
      if (err) {
        console.error("Autocannon error:", err);
      }
      // We don't need to handle the result here as we'll use the 'done' event
    }
  );

  // Track progress
  let progressLogs = 0;
  instance.on("tick", () => {
    // Only log every 5 ticks to reduce noise
    if (progressLogs % 5 === 0) {
      console.log(`Progress: Running benchmark...`);
    }
    progressLogs++;
  });

  // Wait for benchmark to complete
  const result: Result = await new Promise<Result>((resolve) => {
    instance.on("done", (result: Result) => resolve(result));
  });

  // Stop resource monitoring
  monitor.stop();

  // Process results
  const benchmarkResult = processResults(result, {
    url: options.url,
    duration: options.duration,
    connections: options.connections,
    scenario: options.scenario,
    mode: options.mode,
    useCluster: options.useCluster,
  });

  // Add resource usage data
  const resourceSummary = monitor.getSummary();
  Object.assign(benchmarkResult, {
    resources: {
      avgCpuPercentage: resourceSummary.avgCpuPercentage,
      maxCpuPercentage: resourceSummary.maxCpuPercentage,
      avgMemoryUsed: resourceSummary.avgMemoryUsed,
      maxMemoryUsed: resourceSummary.maxMemoryUsed,
    },
  });

  // Save results if output file is specified
  if (options.outputFile) {
    saveResults(benchmarkResult, options.outputFile);
  }

  // Print summary
  console.log("\nBenchmark Summary:");
  console.log(`Total Requests: ${benchmarkResult.summary.totalRequests}`);
  console.log(
    `Successful Requests: ${benchmarkResult.summary.successfulRequests}`
  );
  console.log(`Failed Requests: ${benchmarkResult.summary.failedRequests}`);
  console.log(
    `Requests/sec: ${benchmarkResult.summary.requestsPerSecond.toFixed(2)}`
  );
  console.log(
    `Average Latency: ${benchmarkResult.responseTimes.avg.toFixed(2)} ms`
  );
  console.log(
    `P95 Latency: ${benchmarkResult.responseTimes.p95.toFixed(2)} ms`
  );
  console.log(
    `P99 Latency: ${benchmarkResult.responseTimes.p99.toFixed(2)} ms`
  );
  console.log(
    `Rate Limited %: ${benchmarkResult.summary.rateLimitedRate.toFixed(2)}%`
  );
  console.log(
    `CPU Usage: ${resourceSummary.avgCpuPercentage.toFixed(
      2
    )}% avg, ${resourceSummary.maxCpuPercentage.toFixed(2)}% max`
  );
  console.log(
    `Memory Usage: ${resourceSummary.avgMemoryUsed.toFixed(
      2
    )} MB avg, ${resourceSummary.maxMemoryUsed.toFixed(2)} MB max`
  );
}

// CLI entrypoint when script is executed directly
// Using import.meta.url instead of require.main for ES modules
if (import.meta.url === import.meta.resolve("./autocannon.js")) {
  const args = {
    url: process.env.TARGET_URL || "http://localhost:3000/api/light",
    duration: parseInt(process.env.DURATION || "30", 10),
    connections: parseInt(process.env.CONNECTIONS || "50", 10),
    scenario: (process.env.SCENARIO || "light") as "light" | "heavy",
    mode: process.env.MODE || "valkey-glide",
    useCluster: process.env.USE_CLUSTER === "true",
    output: process.env.OUTPUT_FILE || `./results/benchmark-${Date.now()}.json`,
  };

  runBenchmark({
    url: args.url,
    duration: args.duration,
    connections: args.connections,
    scenario: args.scenario,
    mode: args.mode,
    useCluster: args.useCluster,
    outputFile: args.output,
  }).catch((err) => {
    console.error("Error running benchmark:", err);
    process.exit(1);
  });
}
