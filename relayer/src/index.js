import "dotenv/config";
import { loadConfig } from "./config.js";
import { createApp } from "./app.js";
import { log } from "./lib/logger.js";

const cfg = loadConfig();
const app = createApp(cfg);

app.listen(cfg.port, () => {
  log("info", "relayer listening", {
    port: cfg.port,
    relayerConfigured: true,
    apiKeyRequired: Boolean(cfg.apiKey)
  });
});
