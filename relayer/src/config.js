import fs from "node:fs";
import path from "node:path";
import { ethers } from "ethers";

function readJsonConfig(operationsPath) {
  const configPath = path.isAbsolute(operationsPath)
    ? operationsPath
    : path.resolve(process.cwd(), operationsPath);
  const raw = fs.readFileSync(configPath, "utf8");
  return JSON.parse(raw);
}

export function loadConfig() {
  const RPC_URL = process.env.RPC_URL;
  const RELAYER_PRIVATE_KEY = process.env.RELAYER_PRIVATE_KEY;
  const FORWARDER = process.env.ERC2771_FORWARDER;
  const OPERATIONS_CONFIG = process.env.OPERATIONS_CONFIG ?? "./config/operations.example.json";

  if (!RPC_URL || !RELAYER_PRIVATE_KEY || !FORWARDER) {
    throw new Error("Missing RPC_URL, RELAYER_PRIVATE_KEY or ERC2771_FORWARDER");
  }

  const operations = readJsonConfig(OPERATIONS_CONFIG);
  const tradeManager = operations.contracts?.tradeManager;
  if (!tradeManager || tradeManager === ethers.ZeroAddress) {
    throw new Error("operations config must set contracts.tradeManager to a non-zero address");
  }

  const forwarderEip712Name = process.env.FORWARDER_EIP712_NAME ?? "STOEX Forwarder";
  const forwarderEip712Version = process.env.FORWARDER_EIP712_VERSION ?? "1";

  const apiKey = process.env.RELAYER_API_KEY?.trim() || null;
  const trustProxy = String(process.env.TRUST_PROXY ?? "").toLowerCase() === "true" || process.env.TRUST_PROXY === "1";

  const corsOrigins = (process.env.CORS_ORIGIN ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

  const rateLimitWindowMs = Number(process.env.RATE_LIMIT_WINDOW_MS ?? 900_000);
  const rateLimitMax = Number(process.env.RATE_LIMIT_MAX ?? 200);

  return {
    port: Number(process.env.PORT ?? "8787"),
    rpcUrl: RPC_URL,
    relayerPrivateKey: RELAYER_PRIVATE_KEY,
    forwarder: ethers.getAddress(FORWARDER),
    forwarderEip712Name,
    forwarderEip712Version,
    operationsConfigPath: OPERATIONS_CONFIG,
    operations,
    apiKey,
    trustProxy,
    corsOrigins,
    rateLimitWindowMs,
    rateLimitMax
  };
}
