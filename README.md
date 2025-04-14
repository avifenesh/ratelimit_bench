# Rate Limiter Benchmark

A comprehensive benchmark suite for comparing Valkey and Redis performance with [rate-limiter-flexible](https://github.com/animir/node-rate-limiter-flexible).

## Project Overview

This project benchmarks rate limiting performance using [Valkey](https://valkey.io/) and Redis with the rate-limiter-flexible [package](https://www.npmjs.com/package/rate-limiter-flexible). The main goal is to compare different rate limiter implementations in a fair manner.

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
  - Results collection and processing (`src/benchmark/results.ts`)
  - CPU/memory resource tracking (`src/benchmark/monitor.ts`)
- **Infrastructure**:
  - Docker containers for both standalone and cluster configurations
  - Environment variables (`USE_REDIS_CLUSTER` and `USE_VALKEY_CLUSTER`) controlling cluster mode
  - Runner applications containerized for consistent testing
- **Scripts**:
  - Benchmark orchestration: `scripts/run-benchmark.sh`
  - Full test suite: `scripts/run-all.sh`
  - Report generation: `scripts/generate_report.py` to create HTML reports and CSV summaries

## Getting Started

1. **Install Node.js dependencies:**

    ```bash
    npm install
    ```

2. **Install Python dependencies (for reporting):**
    Ensure you have Python and `uv` installed. It's recommended to use a virtual environment.

    ```bash
    # Create virtual environment (if you don't have one)
    # uv venv
    # Activate virtual environment (e.g., Linux/macOS)
    # source .venv/bin/activate
    uv pip install -r requirements.txt
    ```

3. **Build Docker Images:**
    *(Note: The `run-all.sh` script automatically handles image building. These commands are listed for manual building or understanding the process.)*

    ```bash
    docker build -t benchmark-server:latest -f Dockerfile.server .
    docker build -t benchmark-loadtest:latest -f Dockerfile.loadtest .
    ```

4. **Run Benchmarks:**
    Use the main script to run all tests and generate the report automatically:

    ```bash
    ./scripts/run-all.sh
    ```

    Follow the prompts to choose between a quick or full benchmark run.

## Benchmark Options

You can customize individual benchmark runs using `run-benchmark.sh`:

```bash
# Format: ./scripts/run-benchmark.sh [duration] [concurrency-levels] [request-types] [rate-limiter-types]
# Example: Run only valkey-glide, light workload, 50 connections, 60s duration
./scripts/run-benchmark.sh 60 "50" "light" "valkey-glide"
```

Parameters:

- `duration`: Test duration in seconds (default: 30)
- `concurrency-levels`: Space-separated list of concurrency levels (default: "10 50 100 500 1000")
- `request-types`: Space-separated list of request types (default: "light heavy")
- `rate-limiter-types`: Space-separated list of implementations to test (default: "valkey-glide iovalkey ioredis valkey-glide:cluster iovalkey:cluster ioredis:cluster")

## Client Implementations & Performance

The benchmark tests the following clients (in priority order):

1. **Valkey Glide**
2. **IOValkey**
3. **Redis IORedis**

## Testing Scenarios

The benchmark suite covers a comprehensive range of testing scenarios:

1. **Workload Types**:
   - Light workload: Minimal API processing
   - Heavy workload: Compute-intensive API responses

2. **Run Durations**:
   - Short (30s) to long (2min) tests

3. **Concurrency Levels**:
   - 10, 50, 100, 500, 1000 simultaneous connections

4. **Implementation Variations**:
   - Each client tested in both standalone and cluster modes
   - Cluster configurations use 3 primaries and 3 replicas (6 total nodes)

## Metrics & Performance Focus

The benchmark collects comprehensive metrics to highlight Valkey Glide's performance advantages:

- Throughput (requests per second)
- Latency (avg, p50, p97_5, p99)
- Rate limit hit percentage
- CPU and memory usage

All rate limit settings are kept consistent across implementations for fair performance comparisons, and benchmark visualizations always present Valkey implementations first.

## Generating Reports Manually

The `run-all.sh` script generates the report automatically. To generate it manually for a specific results directory:

```bash
# Make sure your Python virtual environment is active or use uv run
python scripts/generate_report.py ./results/YYYYMMDD_HHMMSS/
# Or using uv run:
# uv run -- python scripts/generate_report.py ./results/YYYYMMDD_HHMMSS/
```

The report (`index.html` and `summary.csv`) will be created inside the specified results directory within a `report/` subdirectory (e.g., `results/YYYYMMDD_HHMMSS/report/`).

## Viewing Results

- The main `results/index.html` provides links to all historical benchmark runs.
- Each run's detailed report is available at `results/YYYYMMDD_HHMMSS/report/index.html`.
- You can open these HTML files directly in your web browser.

## Project Structure

```bash
/home/ubuntu/ratelimit_bench
├── docker/             # Docker volume mounts
├── results/            # Benchmark results (timestamped directories)
│   ├── YYYYMMDD_HHMMSS/
│   │   ├── report/     # Generated HTML report and CSV summary
│   │   │   ├── index.html
│   │   │   └── summary.csv
│   │   ├── *.json      # Raw autocannon results
│   │   └── README.md   # Run-specific details
│   └── latest -> YYYYMMDD_HHMMSS/ # Symlink to the latest run
├── scripts/            # Bash and Python scripts
│   ├── run-all.sh      # Main orchestration script
│   ├── run-benchmark.sh # Individual benchmark runner
│   └── generate_report.py # Python report generator
├── src/                # Source code (TypeScript)
│   ├── benchmark/      # Autocannon and monitoring logic
│   ├── server/         # Fastify server, routes, rate limiter logic
│   └── types/          # Shared TypeScript types
├── tests/              # Unit and integration tests
├── .env.example        # Example environment variables
├── .eslintrc.js        # ESLint configuration
├── .gitignore          # Git ignore rules
├── docker-compose.yml  # Base Docker Compose file (standalone)
├── docker-compose-redis-cluster.yml # Docker Compose for Redis Cluster
├── docker-compose-valkey-cluster.yml # Docker Compose for Valkey Cluster
├── Dockerfile.server   # Dockerfile for the Fastify server
├── Dockerfile.loadtest # Dockerfile for the Autocannon load tester
├── package.json
├── README.md           # This file
├── requirements.txt    # Python dependencies for report generation
├── tsconfig.json       # TypeScript configuration
└── valkey.conf         # Valkey configuration file
```

## Troubleshooting

- **Docker Network Issues**: If containers have trouble communicating, try running:

    ```bash
    scripts/fix-network.sh
    ```

- **Permissions**: Ensure scripts are executable (`chmod +x scripts/*.sh scripts/*.py`).

## Contributing

Contributions are welcome! Please follow the existing code style and ensure tests pass.
