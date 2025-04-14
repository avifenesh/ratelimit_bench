import { Result } from "autocannon";
import { writeFileSync, mkdirSync } from "fs";
import { dirname } from "path";

export interface BenchmarkResult {
  testConfig: {
    url: string;
    duration: number;
    connections: number;
    scenario: string;
    mode: string;
    useCluster: boolean;
    timestamp: string;
  };
  summary: {
    totalRequests: number;
    successfulRequests: number;
    failedRequests: number;
    requestsPerSecond: number;
    successRate: number;
    rateLimitedRate: number;
  };
  responseTimes: {
    min: number;
    avg: number;
    max: number;
    p50: number;
    p90: number;
    p95: number;
    p97_5: number;
    p99: number;
  };
  throughput: {
    bytesPerSecond: number;
    totalBytes: number;
  };
  errors: {
    timeouts: number;
    connectionErrors: number;
    "400s": number;
    "429s": number;
    "500s": number;
  };
}

export function processResults(
  autocannonResult: Result,
  options: {
    url: string;
    duration: number;
    connections: number;
    scenario: string;
    mode: string;
    useCluster: boolean;
  }
): BenchmarkResult {
  // Count rate limited responses (429)
  const rateLimited = Object.keys(autocannonResult.statusCodeStats || {})
    .filter((code) => code === "429")
    .reduce((count, code) => {
      const stat = autocannonResult.statusCodeStats?.[code as `${number}`];
      // Handle both number and object with count property
      const statCount = typeof stat === "number" ? stat : stat?.count || 0;
      return count + statCount;
    }, 0);

  return {
    testConfig: {
      url: options.url,
      duration: options.duration,
      connections: options.connections,
      scenario: options.scenario,
      mode: options.mode,
      useCluster: options.useCluster,
      timestamp: new Date().toISOString(),
    },
    summary: {
      totalRequests: autocannonResult.requests.total,
      successfulRequests:
        autocannonResult.requests.total -
        (autocannonResult.non2xx +
          autocannonResult.errors +
          autocannonResult.timeouts),
      failedRequests:
        autocannonResult.non2xx +
        autocannonResult.errors +
        autocannonResult.timeouts,
      requestsPerSecond: autocannonResult.requests.average,
      successRate:
        ((autocannonResult.requests.total -
          (autocannonResult.non2xx +
            autocannonResult.errors +
            autocannonResult.timeouts)) /
          autocannonResult.requests.total) *
        100,
      rateLimitedRate: (rateLimited / autocannonResult.requests.total) * 100,
    },
    responseTimes: {
      min: autocannonResult.latency.min,
      avg: autocannonResult.latency.average,
      max: autocannonResult.latency.max,
      p50: autocannonResult.latency.p50,
      p90: autocannonResult.latency.p90,
      p97_5: autocannonResult.latency.p97_5,
      p99: autocannonResult.latency.p99,
      p95: 0,
    },
    throughput: {
      bytesPerSecond: autocannonResult.throughput.average,
      totalBytes: autocannonResult.throughput.total,
    },
    errors: {
      timeouts: autocannonResult.timeouts,
      connectionErrors: autocannonResult.errors,
      "400s": Object.keys(autocannonResult.statusCodeStats || {})
        .filter((code) => code.startsWith("4") && code !== "429")
        .reduce((count, code) => {
          const stat = autocannonResult.statusCodeStats?.[code as `${number}`];
          const statCount = typeof stat === "number" ? stat : stat?.count || 0;
          return count + statCount;
        }, 0),
      "429s": rateLimited,
      "500s": Object.keys(autocannonResult.statusCodeStats || {})
        .filter((code) => code.startsWith("5"))
        .reduce((count, code) => {
          const stat = autocannonResult.statusCodeStats?.[code as `${number}`];
          const statCount = typeof stat === "number" ? stat : stat?.count || 0;
          return count + statCount;
        }, 0),
    },
  };
}

/**
 * Save benchmark results to a JSON file
 */
export function saveResults(result: BenchmarkResult, outputPath: string): void {
  // Ensure directory exists
  const dir = dirname(outputPath);
  mkdirSync(dir, { recursive: true });

  // Write results to file
  writeFileSync(outputPath, JSON.stringify(result, null, 2));
  console.log(`Results saved to ${outputPath}`);
}
