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
ratelimit_bench/
├── src/                    # Source TypeScript files
│   ├── benchmark/          # Autocannon benchmark tools with resource monitoring
│   ├── loadtest/           # Load testing utilities
│   └── server/             # Server implementation with rate limiters
│       ├── config/         # Server configuration
│       ├── lib/            # Client and rate limiter factories
│       ├── middleware/     # Fastify middleware
│       └── routes/         # API endpoints
├── scripts/                # Benchmark orchestration scripts
├── docker-compose.yml                  # Main Docker setup for standalone instances
├── docker-compose-redis-cluster.yml    # Redis cluster configuration
└── docker-compose-valkey-cluster.yml   # Valkey cluster configuration
```

## Results

After running benchmarks, results are stored in the `results/` directory. Each test run creates a timestamped folder containing:

- Individual test results as JSON files
- Server logs for each test
- A README.md summarizing the test configuration
- Summary charts and comparisons (if report generation was run)

## Generate Reports

After running benchmarks, you can generate a comprehensive report:

```bash
npm run generate-report
```

This will create visualizations comparing the performance of different implementations.

## License

MIT
