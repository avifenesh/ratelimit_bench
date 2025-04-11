import Fastify from "fastify";
import { createRateLimiter } from "../lib/rateLimiterFactory.js";
import { registerRoutes } from "./routes/index.js";
import { getConfig } from "./config/index.js";

const config = getConfig();
const app = Fastify({
  logger: {
    level: config.logLevel,
  },
});

// Create and register the appropriate rate limiter
const rateLimiter = createRateLimiter(config.mode, config);

// Register routes
registerRoutes(app, { rateLimiter, config });

// Start the server
const start = async () => {
  try {
    await app.listen({ port: config.port, host: "0.0.0.0" });
    console.log(`Server listening on http://0.0.0.0:${config.port}`);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
};

start();
