import { runBenchmark } from "./autocannon.js";

// Get benchmark configuration from environment variables
const targetUrl = process.env.TARGET_URL || "http://localhost:3000";
const duration = parseInt(process.env.DURATION || "30", 10);
const connections = parseInt(process.env.CONNECTIONS || "10", 10);
const requestType = (process.env.REQUEST_TYPE || "light") as "light" | "heavy";
const outputFile = process.env.OUTPUT_FILE;
const rateLimiterType = process.env.RATE_LIMITER_TYPE || "unknown";

async function main() {
  try {
    console.log("Starting benchmark runner...");

    // Run the benchmark
    await runBenchmark({
      url: targetUrl,
      duration,
      connections,
      requestType,
      outputFile,
      rateLimiterType,
    });

    console.log("Benchmark completed successfully.");
    process.exit(0);
  } catch (error) {
    console.error("Benchmark failed:", error);
    process.exit(1);
  }
}

// Start the benchmark
main();
