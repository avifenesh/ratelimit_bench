# Rate Limiter Benchmark

A comprehensive benchmark suite for comparing Valkey and Redis performance with rate-limiter-flexible.

## Project Overview

This project provides a benchmark framework for testing different rate limiter implementations using Valkey and Redis with the rate-limiter-flexible library. The application is fully implemented in TypeScript with Fastify for improved developer experience, type safety, and performance.

## Supported Implementations

The benchmarks compare the following implementations, ordered by their strategic importance:

1. **Valkey Glide** - Modern TypeScript-native Valkey client (primary focus)
2. **Valkey IO** - Valkey client based on ioredis API (secondary focus)
3. **Redis IORedis** - Popular Redis client for Node.js
4. **Redis Node** - Official Node.js Redis client

Each implementation is tested in both standalone and cluster modes (where supported).

## Getting Started

### Prerequisites

- Node.js 18+ and npm
- Docker and Docker Compose
- TypeScript

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/ratelimit_bench.git
cd ratelimit_bench

# Install dependencies
npm install
```

### Running Benchmarks

The project includes a comprehensive benchmark script that tests all configurations:

```bash
# Run all benchmarks with default settings
npm run benchmark

# Run a specific benchmark scenario
npm run benchmark:light  # Light workload tests
npm run benchmark:heavy  # Heavy workload tests

# Run custom benchmark (duration in seconds)
./scripts/run-benchmark.sh 60  # Run with 60 second duration
```

### Custom Benchmark Configurations

You can customize the benchmark parameters:

```bash
# Format: ./scripts/run-benchmark.sh [duration] [concurrency-levels] [request-types] [rate-limiter-types]
./scripts/run-benchmark.sh 30 "10 100" "light" "valkey-glide valkey-glide:cluster"
```

Parameters:

- `duration`: Test duration in seconds (default: 30)
- `concurrency-levels`: Space-separated list of concurrency levels (default: "10 50 100 500 1000")
- `request-types`: Space-separated list of request types (default: "light heavy")
- `rate-limiter-types`: Space-separated list of implementations to test (default: all implementations)

### Running Individual Services

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
npm run start:valkey-io
npm run start:ioredis
npm run start:redis-node
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
