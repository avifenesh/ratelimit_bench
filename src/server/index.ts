import fastify from "fastify";
import routes from "./routes/index.js";
import {
  createRateLimiter,
  closeRateLimiter,
} from "./lib/rateLimiterFactory.js";
import config from "./config/index.js";
// Add Node.js types
import * as process from "process";

// Create a fastify server
const createServer = () => {
  const server = fastify({
    logger: {
      level: config.logLevel,
      transport: {
        target: "pino-pretty",
      },
    },
  });

  // Register routes
  server.register(routes);

  return server;
};

// Start the server
const start = async () => {
  // Initialize rate limiter
  await createRateLimiter();

  const server = createServer();

  try {
    await server.listen({ port: config.port, host: "0.0.0.0" });
    console.log(`Server listening on port ${config.port}`);
    console.log(`Rate limiter mode: ${config.mode}`);
    console.log(`${config.useValkeyCluster ? "Using Valkey Cluster" : ""}`);
    console.log(`${config.useRedisCluster ? "Using Redis Cluster" : ""}`);
  } catch (error) {
    // Type assertion for error
    const err = error as Error;
    server.log.error(err);
    process.exit(1);
  }

  // Graceful shutdown
  process.on("SIGINT", async () => {
    console.log("Stopping server...");
    await closeRateLimiter();
    await server.close();
    process.exit(0);
  });

  process.on("SIGTERM", async () => {
    console.log("Stopping server...");
    await closeRateLimiter();
    await server.close();
    process.exit(0);
  });
};

// Start the server
start();
