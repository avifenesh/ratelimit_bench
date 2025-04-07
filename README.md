# Rate Limiter Benchmark Suite

A comprehensive benchmarking toolkit for evaluating and comparing rate limiter implementations.

## Introduction

This project provides tools to benchmark various rate limiter implementations from the `rate-limiter-flexible` library, allowing developers to make informed decisions based on objective performance data.

## Key Features

- **Comprehensive Testing**: Evaluates performance under various load conditions
- **Multiple Implementations**: Tests both Valkey and Redis-based rate limiters
- **Realistic Conditions**: Simulates real-world production traffic patterns
- **Detailed Metrics**: Collects and analyzes performance statistics
- **Automated Execution**: Simple to run with minimal configuration
- **High-Performance**: Uses Fastify for maximum throughput during benchmarks

## Rate Limiters Tested

- **Valkey-Glide**: Modern TypeScript client for Valkey (`@valkey/valkey-glide`)
- **IOValkey**: Node.js client for Valkey (`iovalkey`)
- **IORedis**: Popular Redis client for Node.js
- **Node-Redis**: Official Redis client for Node.js

## Performance Factors

Multiple factors can impact rate limiter performance:

- Connection management efficiency
- Protocol implementation
- Memory usage patterns
- Request handling architecture
- Client library optimizations

The benchmarks are designed to isolate these factors to provide clear insights into which implementation might be most suitable for different use cases.

## Getting Started

The benchmark suite is located in the `bench` directory:

```bash
cd bench
```

Follow the instructions in the [benchmark README](bench/README.md) to run the tests.

## Project Structure

```
ratelimit_bench/
├── bench/                   # Main benchmark implementation
│   ├── docker/              # Docker configurations
│   ├── src/                 # Source code for benchmarks
│   │   ├── server/          # Fastify server with rate limiters
│   │   ├── k6/              # k6 load testing scripts
│   │   └── node-loadtest/   # Node.js load testing implementation
│   ├── results/             # Benchmark results (generated)
│   ├── run-benchmark.sh     # Main benchmark script
│   └── README.md            # Benchmark documentation
```

## License

MIT
