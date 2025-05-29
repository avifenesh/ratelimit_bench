# Rate Limiter Benchmark

A comprehensive benchmark suite for comparing [rate-limiter-flexible](https://github.com/animir/node-rate-limiter-flexible) options using Valkey and Redis clients.

<div align="center">
  <a href="https://avifenesh.github.io/ratelimit_bench/" target="_blank">
    <img src="https://img.shields.io/badge/View%20Interactive-HTML%20Report-blue?style=for-the-badge" alt="View Interactive HTML Report">
  </a>
</div>
<p align="center">
  <a href="#benchmark-results">
    <img src="https://img.shields.io/badge/View%20Results-Benchmark%20Data-blue?style=for-the-badge" alt="View Benchmark Results">
  </a>
</p>

[CSV Summary Data](https://avifenesh.github.io/ratelimit_bench/summary.csv) - Raw benchmark metrics

## Project Overview

This project benchmarks rate limiting performance using [Valkey](https://valkey.io/) and Redis-OSS with the rate-limiter-flexible [package](https://www.npmjs.com/package/rate-limiter-flexible).
The benchmark provides an objective comparison between different rate limiter implementations to help developers choose the most performant solution for their applications.

**Disclosure:** This project is developed and maintained by a [valkey-glide](https://github.com/valkey-io/valkey-glide) maintainer.  
To use valkey-glide you can visit [npm](https://www.npmjs.com/package/@valkey/valkey-glide), for usage with rate-limiter-flexible refer to the [documentation](https://github.com/animir/node-rate-limiter-flexible/wiki/Valkey-Glide).

## Architecture

- **Server**: Fastify-based API server with rate limiting middleware
  - Main server (`src/server/index.ts`)
  - Configuration (`src/server/config/index.ts`)
  - API routes (`src/server/routes/index.ts`)
  - Rate limiter factory (`src/server/lib/rateLimiterFactory.ts`)
  - Client management (`src/server/lib/clientFactory.ts`)

- **Valkey and Redis used as backends for rate limiting**
  - **Valkey**: Latest at the point of the benchmark - v8.1.0
  - **Redis**: Latest OSS version which wasn't published as Valkey as well - v7.0.0

- **Rate Limiters**: Using rate-limiter-flexible with different backends:
  - **Valkey Glide** – Modern TypeScript-native client, built with a focus on stability, reliability, performance, and scalability. Designed specifically to provide superior fault tolerance and user experience.
  - **IOValkey** – Client based on the ioredis API, enhanced with Valkey performance.
  - **Redis IORedis** – Popular Redis client for Node.js

- **Benchmark Layer**:
  - Autocannon for HTTP load testing with resource monitoring (`src/benchmark/autocannon.ts`)
  - Environment variable configuration for benchmark parameters
  - CPU/memory resource tracking (`src/benchmark/monitor.ts`)

- **Infrastructure**:
  - Docker containers for both standalone and cluster configurations
  - Docker Compose files for easy deployment
  - Environment variables controlling cluster mode
  - Dedicated benchmark network for consistent results

- **Scripts**:
  - Benchmark orchestration: `scripts/run-all.sh` for full test suite
  - Individual benchmark runner: `scripts/run-benchmark.sh`
  - Report generation: `scripts/generate_report.py` creates HTML reports and CSV summaries
  - Network troubleshooting: `scripts/fix-network.sh`

## Getting Started

1. **Install Node.js dependencies:**

    ```bash
    npm install
    ```

2. **Install Python dependencies (for reporting):**
    Ensure you have Python installed. It's recommended to use a virtual environment.

    ```bash
    pip install -r requirements.txt
    ```

3. **Run Benchmarks:**

### Interactive Mode (Recommended)

Run the enhanced script without arguments for a guided configuration:

```bash
./scripts/run-all.sh
```

This provides an interactive menu to select:
- **Specific clients**: Choose individual clients (valkey-glide, iovalkey, ioredis) or groups (standalone, cluster, all)
- **Workload types**: Light, heavy, or both computational workloads
- **Duration mode**:
  - Dynamic (120s for ≤100 connections, 180s for >100 connections, +30s for cluster)
  - Fixed durations (30s, 120s, or custom)
- **Concurrency levels**: Light load (50-100), medium (50-500), heavy (50-1000), extreme (100-2000), or custom

### Non-Interactive Mode

Run with command line arguments for automated execution:

```bash
# Test only valkey-glide standalone with light workload and dynamic duration
./scripts/run-all.sh --clients valkey-glide --workload light --duration-mode dynamic --concurrency "50 100"

# Test all standalone clients with both workloads and fixed 30s duration
./scripts/run-all.sh --clients standalone --workload both --duration-mode fixed30 --concurrency "50 100"

# Test all cluster implementations with heavy workload and custom duration
./scripts/run-all.sh --clients cluster --workload heavy --duration-mode custom:90 --concurrency "100 500"

# Test specific clients with dynamic duration (optimal for each concurrency/cluster combination)
./scripts/run-all.sh --clients "valkey-glide,iovalkey:cluster" --workload light --duration-mode dynamic --concurrency "50 200 500"
```

### Available Options

- `--clients`: Specify client(s) to test
  - Individual: `valkey-glide`, `iovalkey`, `ioredis`
  - With cluster: `valkey-glide:cluster`, `iovalkey:cluster`, `ioredis:cluster`
  - Groups: `all`, `standalone`, `cluster`
  - Custom list (comma-separated): `valkey-glide,iovalkey:cluster`
- `--workload`: Workload type (`light`, `heavy`, `both`)
- `--duration-mode`: Duration calculation method
  - `dynamic`: 120s for ≤100 connections, 180s for >100 connections, +30s for cluster
  - `fixed30`: Fixed 30 seconds for all tests
  - `fixed120`: Fixed 120 seconds for all tests
  - `custom:N`: Custom duration of N seconds
- `--concurrency`: Concurrency level(s) (space-separated for multiple)
- `--help`: Show detailed help with examples

### Dynamic Duration Logic

The dynamic duration mode automatically adjusts test duration based on:

- **Concurrency**: 120s for 50-100 connections, 180s for 500-1000 connections
- **Cluster**: Additional 30s for cluster configurations (allows for cluster coordination overhead)

Examples:

- valkey-glide with 50 connections: 120s
- valkey-glide with 500 connections: 180s  
- valkey-glide:cluster with 50 connections: 150s (120s + 30s)
- valkey-glide:cluster with 500 connections: 210s (180s + 30s)

### Legacy Mode

The script still supports the original simple prompts when called without the enhanced options above.

## Benchmark Options

The enhanced `run-all.sh` script provides granular control over benchmark execution. For advanced users, you can also customize individual runs using the underlying `run-benchmark.sh` script with environment variables:

```bash
# Example: Run a 60-second benchmark with 50 connections using the light workload against valkey-glide
DURATION=60 CONNECTIONS=50 REQUEST_TYPE=light RATE_LIMITER_TYPE=valkey-glide ./scripts/run-benchmark.sh
```

Available environment variables:

- `DURATION`: Test duration in seconds (default: 30)
- `CONNECTIONS`: Number of concurrent connections (default: 10)
- `REQUEST_TYPE`: Workload type (default: "light", options: "light" or "heavy")
- `RATE_LIMITER_TYPE`: Implementation to test (default: "unknown")
- `OUTPUT_FILE`: Path to save benchmark results (optional)

## Client Implementations

The benchmark tests the following clients:

1. **Valkey Glide** -  Modern TypeScript-native client, built with a focus on stability, reliability, performance, and scalability. Designed specifically to provide superior fault tolerance and user experience.
2. **IOValkey** - Client based on the ioredis API with Valkey performance
3. **Redis IORedis** - Standard Redis client for Node.js

Each client is tested in both standalone and cluster configurations.

## Testing Scenarios

The benchmark suite covers multiple testing scenarios:

1. **Workload Types**:
   - Light workload: Minimal API processing
   - Heavy workload: Compute-intensive API responses (configurable complexity level)

2. **Run Durations**:
   - Short (30s) for quick comparisons
   - Medium (120s) for sustained performance analysis
   - Extended (150s) for 50-100 connection tests with heavy workloads
   - Long (180-210s) for high concurrency tests (500-1000 connections)

3. **Concurrency Levels**:
   - 50 connections: Base testing level for all configurations
   - 100 connections: Medium load testing for all configurations
   - 500 connections: High load testing for standalone mode
   - 1000 connections: Extreme load testing for cluster mode

4. **Deployment Variations**:
   - Standalone: Single Redis/Valkey instance
   - Cluster: 6-node configuration (3 primaries, 3 replicas)

5. **Client Implementations**:
   - Valkey Glide (both standalone and cluster modes)
   - IOValkey (both standalone and cluster modes)
   - Redis IORedis (both standalone and cluster modes)

6. **Test Iterations**:
   - Each configuration runs 3 times to ensure statistical significance
   - Includes 10-second warmup period before each test
   - 5-second cooldown between test configurations
   - 10-second cooldown between different client implementations

## Metrics Collected

The benchmark collects the following performance metrics:

- **Throughput**: Requests per second
- **Latency**: Average, median (p50), p97.5, and p99 response times
- **Rate Limiting**: Percentage of requests that hit rate limits
- **System Resources**: CPU and memory usage during benchmarks
- **Error Rates**: Percentage of failed requests

## Benchmark Methodology and Results Processing

To ensure statistical significance and account for system variability, each benchmark configuration is run multiple times (typically three iterations). This approach minimizes the impact of outliers and transient system behavior.

The data processing methodology follows these steps:

1. **Multiple Iterations**: Each benchmark configuration (client/workload/concurrency combination) is executed three consecutive times with identical parameters.
2. **Median Selection**: For each performance metric, the median value from all runs is selected for the final report, providing a more stable representation than a single run or a mean value that could be skewed by outliers.
3. **Consistency Verification**: Standard deviation is calculated across runs to ensure test stability. High variance may indicate unstable test conditions and is flagged in the report.
4. **Comparative Analysis**: Percentage differences between implementations are calculated to highlight relative performance characteristics.

This methodology ensures the benchmark results are:

- **Reproducible**: Multiple runs increase confidence in the measurements
- **Representative**: Median values avoid skew from outliers
- **Comparable**: Consistent methodology across all client implementations

## Results Structure

Benchmark results are organized by timestamp in the `results/` directory:

```text
results/
├── YYYYMMDD_HHMMSS/            # Timestamp-based directory for each run
│   ├── benchmark.log           # Full log output from the benchmark
│   ├── README.md               # Run-specific details
│   ├── {implementation}_{workload}_{connections}c_{duration}s_run{N}.json      # Raw data
│   └── {implementation}_{workload}_{connections}c_{duration}s_run{N}.json.log  # Logs
└── latest -> YYYYMMDD_HHMMSS/  # Symlink to most recent run
```

Example result file: `valkey-glide_light_100c_30s_run1.json`

## Current Project Structure

```text
/home/ubuntu/ratelimit_bench
├── docker/                            # Docker volume mounts
│   └── app/                           # Application code for Docker
├── results/                           # Benchmark results
│   ├── YYYYMMDD_HHMMSS/               # Timestamp-based directories
│   └── latest -> YYYYMMDD_HHMMSS/     # Symlink to latest run
├── scripts/
│   ├── fix-network.sh                 # Docker network troubleshooting
│   ├── generate_report.py             # Python report generator
│   ├── run-all.sh                     # Main benchmark orchestration
│   └── run-benchmark.sh               # Individual benchmark runner
├── src/
│   ├── benchmark/                     # Benchmark code
│   │   ├── autocannon.ts              # HTTP benchmarking using autocannon
│   │   ├── index.ts                   # Benchmark entry point
│   │   └── monitor.ts                 # Resource monitoring utilities
│   └── server/                        # Server implementation
│       ├── config/                    # Server configuration
│       ├── lib/                       # Core libraries and utilities
│       ├── middleware/                # Server middleware including rate limiting
│       └── routes/                    # API route definitions
├── docker-compose.yml                 # Base Docker Compose configuration
├── docker-compose-redis-cluster.yml   # Redis cluster configuration
├── docker-compose-valkey-cluster.yml  # Valkey cluster configuration
├── Dockerfile.loadtest                # Dockerfile for benchmark runner
├── Dockerfile.server                  # Dockerfile for API server
├── redis.conf                         # Redis configuration
├── valkey.conf                        # Valkey configuration
├── package.json                       # Node.js dependencies and scripts
├── tsconfig.json                      # TypeScript configuration
└── requirements.txt                   # Python dependencies for reporting
```

## Troubleshooting

- **Docker Network Issues**: If containers have trouble communicating, try running:

    ```bash
    ./scripts/fix-network.sh
    ```

- **Permissions Issues**: Ensure scripts are executable:

    ```bash
    chmod +x ./scripts/*.sh ./scripts/*.py
    ```

- **Container Cleanup**: To remove all containers and start fresh:

    ```bash
    docker-compose down -v
    docker-compose -f docker-compose-redis-cluster.yml down -v
    docker-compose -f docker-compose-valkey-cluster.yml down -v
    ```

## Contributing

Contributions are welcome! Please follow the existing code style and ensure tests pass before submitting pull requests.

## License

This project is open source and available under the [MIT License](LICENSE).

<a name="benchmark-results"></a>

## Benchmark Results

The benchmark results below compare the performance of different rate limiter implementations across various scenarios. Data is collected from extensive testing under controlled conditions to ensure fair comparison.

### Interactive Results Report

For the best experience, view the full interactive benchmark report:

<div align="center">
  <a href="https://avifenesh.github.io/ratelimit_bench/" target="_blank">
    <img src="https://img.shields.io/badge/View%20Interactive-HTML%20Report-blue?style=for-the-badge" alt="View Interactive HTML Report">
  </a>
</div>

### Key Findings (Generated on: April 16, 2025)

- **Valkey Glide** consistently outperforms other clients in both standalone and cluster configurations
- Performance differences become more pronounced under higher concurrency scenarios (500-1000 connections)
- All clients demonstrate stable performance across multiple test runs, validating reproducibility of results
- At high concurrency (1000 connections), Valkey Glide maintains significantly lower latency compared to IORedis

### Cluster Mode Results

<table class="dataframe results-table">
  <thead>
    <tr>
      <th>Client</th>
      <th>Mode</th>
      <th>RequestType</th>
      <th>Concurrency</th>
      <th>Duration</th>
      <th>ReqPerSec</th>
      <th>Latency_Avg</th>
      <th>Latency_P50</th>
      <th>Latency_P99</th>
      <th>RateLimitHits</th>
      <th>CPUUsage</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>valkey-glide</td>
      <td>cluster</td>
      <td>heavy</td>
      <td>50</td>
      <td>150</td>
      <td>6,064,837</td>
      <td>2.04</td>
      <td>2.00</td>
      <td>3.00</td>
      <td>3,173,724</td>
      <td>53.30</td>
    </tr>
    <tr>
      <td>iovalkey</td>
      <td>cluster</td>
      <td>heavy</td>
      <td>50</td>
      <td>150</td>
      <td>5,240,067</td>
      <td>2.12</td>
      <td>2.00</td>
      <td>3.00</td>
      <td>2,742,213</td>
      <td>45.59</td>
    </tr>
    <tr>
      <td>ioredis</td>
      <td>cluster</td>
      <td>heavy</td>
      <td>50</td>
      <td>150</td>
      <td>4,484,765</td>
      <td>2.84</td>
      <td>3.00</td>
      <td>4.00</td>
      <td>2,346,830</td>
      <td>38.16</td>
    </tr>
    <tr>
      <td>valkey-glide</td>
      <td>cluster</td>
      <td>heavy</td>
      <td>1000</td>
      <td>210</td>
      <td>3,332,332</td>
      <td>84.91</td>
      <td>71.00</td>
      <td>519.00</td>
      <td>2,441,648</td>
      <td>35.79</td>
    </tr>
    <tr>
      <td>iovalkey</td>
      <td>cluster</td>
      <td>heavy</td>
      <td>1000</td>
      <td>210</td>
      <td>3,168,085</td>
      <td>90.02</td>
      <td>82.00</td>
      <td>241.00</td>
      <td>2,321,125</td>
      <td>34.00</td>
    </tr>
    <tr>
      <td>ioredis</td>
      <td>cluster</td>
      <td>heavy</td>
      <td>1000</td>
      <td>210</td>
      <td>1,246,590</td>
      <td>143.87</td>
      <td>97.00</td>
      <td>1,640.00</td>
      <td>913,144</td>
      <td>18.71</td>
    </tr>
  </tbody>
</table>

### Standalone Mode Results

<table class="dataframe results-table">
  <thead>
    <tr>
      <th>Client</th>
      <th>Mode</th>
      <th>RequestType</th>
      <th>Concurrency</th>
      <th>Duration</th>
      <th>ReqPerSec</th>
      <th>Latency_Avg</th>
      <th>Latency_P50</th>
      <th>Latency_P99</th>
      <th>RateLimitHits</th>
      <th>CPUUsage</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>valkey-glide</td>
      <td>standalone</td>
      <td>heavy</td>
      <td>50</td>
      <td>150</td>
      <td>6,164,561</td>
      <td>2.01</td>
      <td>2.00</td>
      <td>3.00</td>
      <td>3,225,896</td>
      <td>53.89</td>
    </tr>
    <tr>
      <td>iovalkey</td>
      <td>standalone</td>
      <td>heavy</td>
      <td>50</td>
      <td>150</td>
      <td>5,558,435</td>
      <td>2.05</td>
      <td>2.00</td>
      <td>3.00</td>
      <td>2,908,731</td>
      <td>49.84</td>
    </tr>
    <tr>
      <td>ioredis</td>
      <td>standalone</td>
      <td>heavy</td>
      <td>50</td>
      <td>150</td>
      <td>4,680,253</td>
      <td>2.33</td>
      <td>2.00</td>
      <td>4.00</td>
      <td>2,449,174</td>
      <td>41.43</td>
    </tr>
    <tr>
      <td>valkey-glide</td>
      <td>standalone</td>
      <td>heavy</td>
      <td>500</td>
      <td>210</td>
      <td>3,656,168</td>
      <td>38.60</td>
      <td>33.00</td>
      <td>113.00</td>
      <td>2,678,727</td>
      <td>35.99</td>
    </tr>
    <tr>
      <td>iovalkey</td>
      <td>standalone</td>
      <td>heavy</td>
      <td>500</td>
      <td>210</td>
      <td>1,613,720</td>
      <td>62.11</td>
      <td>46.00</td>
      <td>784.00</td>
      <td>1,182,155</td>
      <td>19.15</td>
    </tr>
    <tr>
      <td>ioredis</td>
      <td>standalone</td>
      <td>heavy</td>
      <td>500</td>
      <td>210</td>
      <td>1,608,894</td>
      <td>66.28</td>
      <td>48.00</td>
      <td>794.00</td>
      <td>1,178,439</td>
      <td>19.85</td>
    </tr>
  </tbody>
</table>

### Performance Analysis

1. **Throughput Comparison**:
   - In cluster mode with heavy workload (50 connections), valkey-glide achieves **35% higher throughput** than ioredis
   - At high concurrency (1000 connections), valkey-glide maintains a **167% throughput advantage** over ioredis

2. **Latency Comparison**:
   - valkey-glide consistently maintains lower latency at all concurrency levels
   - P99 latency for valkey-glide at high concurrency (1000 conn) is **68% lower** than ioredis in cluster mode

3. **Scalability**:
   - valkey-glide shows superior handling of increased concurrency with significantly better latency and throughput preservation
   - All clients show performance degradation at extreme concurrency, but valkey-glide degrades more gracefully

### Raw Data Access

All benchmark data is available in the following formats:

- [Interactive HTML Report](https://avifenesh.github.io/ratelimit_bench/) - Visual charts and complete results
- [CSV Summary Data](https://avifenesh.github.io/ratelimit_bench/summary.csv) - Raw benchmark metrics

*Last updated: April 16, 2025*
