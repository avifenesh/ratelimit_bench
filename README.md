# Rate Limiter Benchmark

A comprehensive benchmark suite for comparing Valkey and Redis performance with [rate-limiter-flexible](https://github.com/animir/node-rate-limiter-flexible).

## Project Overview

This project benchmarks rate limiting performance using [Valkey](https://valkey.io/) and Redis with the rate-limiter-flexible [package](https://www.npmjs.com/package/rate-limiter-flexible). The main goal is to compare different rate limiter implementations in a fair manner – but with a focus on highlighting Valkey and [Valkey Glide's](<https://github.com/valkey-io/valkey-glide>) performance advantages.

## Architecture

- **Server**: Fastify-based API server with rate limiting middleware  
  • Main server (`src/server/index.ts`)  
  • API routes including Prometheus metrics at `/metrics` (`src/server/routes/index.ts`)
- **Rate Limiters**: Using rate-limiter-flexible with various backends:
  - **Valkey Glide** – Modern TypeScript-native client for Valkey, built with main focus on stability, reliability, performance, and scalability. Glide was designed with years of experience with users pains, with other clients, with the goal to bring fault tolerance and user experience to the next level.
  - **IOValkey** – Client based on the ioredis API, enhanced for performance using valkey.
  - **Redis IORedis** – Popular Redis client for Node.js
- **Benchmark Layer**:  
  • Autocannon loads tests with resource monitoring (`src/benchmark/autocannon.ts`)  
  • Results collection and processing (`src/benchmark/results.ts`)  
  • CPU/memory resource tracking (`src/benchmark/monitor.ts`)
- **Infrastructure**:  
  • Docker containers for both standalone and cluster configurations  
  • Environment variables (`USE_REDIS_CLUSTER` and `USE_VALKEY_CLUSTER`) controlling cluster mode
- **Monitoring**:  
  • Prometheus metrics endpoint integrated on `/metrics`  
  • Grafana dashboards for visualizations

## Getting Started

1. Install dependencies:

   ```bash
   npm install
   ```

2. Set the environment variables as needed (e.g. `USE_VALKEY_CLUSTER=true` for cluster mode).

3. Run benchmarks:
   - Use `scripts/run-benchmark.sh` for a single benchmark run.
   - Run `scripts/run-all.sh` to execute all tests and generate reports.
4. Generate the report visualizations:

   ```bash
   scripts/generate-report.sh
   ```

5. For troubleshooting Docker network issues, use:

   ```bash
   scripts/fix-network.sh
   ```

## Benchmark Options

You can customize the benchmark parameters:

```bash
# Format: ./scripts/run-benchmark.sh [duration] [concurrency-levels] [request-types] [rate-limiter-types]
./scripts/run-benchmark.sh 30 "10 100" "light" "valkey-glide valkey-glide:cluster"
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

All rate limit settings are kept consistent across implementations for fair performance comparisons, and benchmark visualizations always present Valkey implementations first.

## Individual Services

Start specific services:

```bash
# Start just the databases
npm run docker:up

# Start specific database services
npm run docker:valkey:up
npm run docker:redis:up
npm run docker:valkey-cluster:up
npm run docker:redis-cluster:up

# Run the server with specific configuration
npm run start:valkey-glide
npm run start:iovalkey
npm run start:ioredis
npm run start:valkey-cluster
npm run start:redis-cluster
```

## Architecture

The benchmark uses a layered architecture:

1. **Web Server**: Built with Fastify for high-performance request handling
2. **Rate Limiter**: Uses the rate-limiter-flexible package for consistent rate limiting across clients
3. **Client Libraries**: Various Redis and Valkey client implementations
4. **Load Testing**: Autocannon for reliable HTTP load testing and metrics collection

## Project Structure

```
/home/ubuntu/ratelimit_bench
├── docker/             # Docker volume mounts
├── grafana/            # Grafana provisioning and dashboards
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

## Running the Benchmarks

1.  **Build Docker Images:**
    ```bash
    docker build -t benchmark-server:latest -f Dockerfile.server .
    docker build -t benchmark-loadtest:latest -f Dockerfile.loadtest .
    ```

2.  **Run the Full Suite:**
    The `run-all.sh` script orchestrates the entire benchmark process, including setting up the environment, starting containers, running tests for all configurations, and generating the final report.
    ```bash
    ./scripts/run-all.sh
    ```
    This will create a timestamped results directory (e.g., `results/YYYYMMDD_HHMMSS/`) and a `results/latest` symlink pointing to it.

3.  **Run Individual Benchmarks (Optional):**
    You can use `run-benchmark.sh` for more granular control.
    ```bash
    # Example: Run only valkey-glide, light workload, 50 connections, 60s duration
    ./scripts/run-benchmark.sh 60 "50" "light" "valkey-glide"
    ```

## Generating Reports

The benchmark results are processed into an HTML report with charts and a summary CSV file.

1.  **Install Python Dependencies:**
    The report generation script requires `pandas` and `matplotlib`. Install them using `uv` (preferably within a virtual environment):
    ```bash
    # Activate your virtual environment first (e.g., source .venv/bin/activate)
    uv pip install -r requirements.txt
    ```

2.  **Generate Report:**
    The `run-all.sh` script automatically generates the report after the benchmarks complete. To generate it manually for a specific results directory:
    ```bash
    # Make sure your virtual environment is active or use uv run
    python scripts/generate_report.py ./results/YYYYMMDD_HHMMSS/
    # Or using uv run:
    # uv run -- python scripts/generate_report.py ./results/YYYYMMDD_HHMMSS/
    ```
    The report ( `index.html` and `summary.csv`) will be created inside the specified results directory within a `report/` subdirectory (e.g., `results/YYYYMMDD_HHMMSS/report/`).

## Viewing Results

-   The main `results/index.html` provides links to all historical benchmark runs.
-   Each run's detailed report is available at `results/YYYYMMDD_HHMMSS/report/index.html`.
-   The `run-all.sh` script offers to start a simple HTTP server at the end for easy viewing at `http://localhost:8080`.

## Monitoring

-   **Prometheus:** Access at `http://localhost:9090`
-   **Grafana:** Access at `http://localhost:3000` (Default user/pass: admin/admin)
    -   Import dashboards from the `grafana/dashboards` directory.

## Contributing

...
