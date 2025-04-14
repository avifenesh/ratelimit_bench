# Rate Limiter Benchmark

A comprehensive benchmark suite for comparing [rate-limiter-flexible](https://github.com/animir/node-rate-limiter-flexible) options using Valkey and Redis clients.

## Project Overview

This project benchmarks rate limiting performance using [Valkey](https://valkey.io/) and Redis-OSS with the rate-limiter-flexible [package](https://www.npmjs.com/package/rate-limiter-flexible).
The benchmark provides an objective comparison between different rate limiter implementations to help developers choose the most performant solution for their applications.

Disclosure: This project is developed and maintained by a [valkey-glide](https://github.com/valkey-io/valkey-glide) maintainer.
To use valkey-glide you can visit npm [here](https://www.npmjs.com/package/@valkey/valkey-glide), for usage with rate-limiter-flexible refer to the [documentation](https://github.com/animir/node-rate-limiter-flexible/wiki/Valkey-Glide).

## Architecture

- **Server**: Fastify-based API server with rate limiting middleware
  - Main server (`src/server/index.ts`)
  - Configuration (`src/server/config/index.ts`)
  - API routes (`src/server/routes/index.ts`)
  - Rate limiter factory (`src/server/lib/rateLimiterFactory.ts`)
  - Client management (`src/server/lib/clientFactory.ts`)

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
    Use the main script to run all tests and generate the report automatically:

    ```bash
    ./scripts/run-all.sh
    ```

    Follow the prompts to choose between:
    - Quick Benchmark (light workload)
    - Full Benchmark (light workload and heavy workload)

## Benchmark Options

The `run-all.sh` script provides a comprehensive benchmark suite, but you can also customize individual runs using environment variables:

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

1. **Valkey Glide** - Modern TypeScript client optimized for Valkey
2. **IOValkey** - Client based on the ioredis API with Valkey performance
3. **Redis IORedis** - Standard Redis client for Node.js

Each client is tested in both standalone and cluster configurations.

## Testing Scenarios

The benchmark suite covers multiple testing scenarios:

1. **Workload Types**:
   - Light workload: Minimal API processing
   - Heavy workload: Compute-intensive API responses

2. **Run Durations**:
   - Short (30s) for quick comparisons
   - Long (120s) for sustained performance analysis

3. **Concurrency Levels**:
   - 10, 50, 100, 500, 1000 simultaneous connections

4. **Deployment Variations**:
   - Standalone: Single Redis/Valkey instance
   - Cluster: 6-node configuration (3 primaries, 3 replicas)

## Metrics Collected

The benchmark collects the following performance metrics:

- **Throughput**: Requests per second
- **Latency**: Average, median (p50), p97.5, and p99 response times
- **Rate Limiting**: Percentage of requests that hit rate limits
- **System Resources**: CPU and memory usage during benchmarks
- **Error Rates**: Percentage of failed requests

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
