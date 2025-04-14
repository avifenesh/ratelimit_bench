import Fastify from "fastify";
import routes from "./routes/index.js";
import { getConfig } from "./config/index.js";
import { rateLimiter } from "./middleware/rateLimiter.js";
const config = getConfig();
const app = Fastify({
  logger: {
    level: config.logLevel,
  },
});

app.addHook("preHandler", rateLimiter);

await app.register(routes, {
  config,
});

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
