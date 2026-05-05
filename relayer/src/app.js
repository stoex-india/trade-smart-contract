import express from "express";
import cors from "cors";
import rateLimit from "express-rate-limit";
import { ethers } from "ethers";
import { loadConfig } from "./config.js";
import {
  buildMetaTxRequest,
  createForwarderContract,
  eip712TypedData,
  normalizeAddress,
  toForwardRequestData
} from "./lib/forwarder.js";
import { createPrecheckContract, precheckBuy, precheckRedeem, precheckSell, precheckRaw } from "./lib/precheck.js";
import { parseRelayReceipt } from "./lib/parseReceipt.js";
import { log } from "./lib/logger.js";
import { requestIdMiddleware } from "./middleware/requestId.js";
import { apiKeyMiddleware } from "./middleware/apiKey.js";

function sendError(res, status, code, message, details) {
  res.status(status).json({
    error: {
      code,
      message,
      ...(details != null ? { details } : {})
    }
  });
}

function coerceArgsArray(args) {
  if (args == null) return [];
  if (!Array.isArray(args)) {
    const err = new Error("args must be an array");
    err.code = "INVALID_BODY";
    throw err;
  }
  return args;
}

export function createApp(cfg = loadConfig()) {
  const provider = new ethers.JsonRpcProvider(cfg.rpcUrl);
  const wallet = new ethers.Wallet(cfg.relayerPrivateKey, provider);
  const forwarder = createForwarderContract(cfg.forwarder, wallet);
  const tradeManagerAddr = normalizeAddress(cfg.operations.contracts.tradeManager);
  const precheckTm = createPrecheckContract(tradeManagerAddr, provider);

  const app = express();
  if (cfg.trustProxy) {
    app.set("trust proxy", 1);
  }

  app.use(requestIdMiddleware);
  app.use(
    cors({
      origin:
        cfg.corsOrigins.length === 0
          ? false
          : cfg.corsOrigins.includes("*")
            ? true
            : cfg.corsOrigins
    })
  );
  app.use(express.json({ limit: "1mb" }));
  app.use(apiKeyMiddleware(cfg.apiKey));

  const limiter = rateLimit({
    windowMs: cfg.rateLimitWindowMs,
    max: cfg.rateLimitMax,
    standardHeaders: true,
    legacyHeaders: false,
    skip: (req) => req.path === "/v1/health"
  });
  app.use(limiter);

  async function metaTxTypedDataHandler(req, res) {
    try {
      const { operation, from, args, deadlineSeconds } = req.body ?? {};
      if (!operation || !from) {
        sendError(res, 400, "INVALID_BODY", "operation and from are required");
        return;
      }
      const request = await buildMetaTxRequest({
        config: cfg.operations,
        forwarder,
        operation,
        from: normalizeAddress(from),
        args: coerceArgsArray(args),
        deadlineSeconds
      });
      const chain = await provider.getNetwork();
      const typed = eip712TypedData({
        chainId: Number(chain.chainId),
        verifyingContract: cfg.forwarder,
        name: cfg.forwarderEip712Name,
        version: cfg.forwarderEip712Version,
        request
      });
      res.json({
        operation,
        domain: typed.domain,
        types: typed.types,
        message: typed.message,
        meta: {
          relayer: wallet.address,
          forwarder: cfg.forwarder,
          tradeManager: tradeManagerAddr
        }
      });
    } catch (error) {
      const code = error.code ?? "TYPED_DATA_FAILED";
      log("error", "typed-data failed", { err: String(error.message ?? error), requestId: req.requestId });
      sendError(res, 400, code, String(error.message ?? error));
    }
  }

  async function metaTxRelayHandler(req, res) {
    try {
      const { operation, from, args, deadlineSeconds, signature } = req.body ?? {};
      if (!operation || !from || !signature) {
        sendError(res, 400, "INVALID_BODY", "operation, from, and signature are required");
        return;
      }
      const request = await buildMetaTxRequest({
        config: cfg.operations,
        forwarder,
        operation,
        from: normalizeAddress(from),
        args: coerceArgsArray(args),
        deadlineSeconds
      });
      const forwardReq = toForwardRequestData(request, signature);
      const ok = await forwarder.verify(forwardReq);
      if (!ok) {
        sendError(res, 400, "VERIFY_FAILED", "Forwarder verify() returned false");
        return;
      }
      const tx = await forwarder.execute(forwardReq, { value: 0 });
      const receipt = await tx.wait();
      const parsed = parseRelayReceipt(receipt, { tradeManagerAddress: tradeManagerAddr });
      if (parsed.forward && parsed.forward.success === false) {
        log("error", "forwarder reported unsuccessful inner call", {
          txHash: tx.hash,
          requestId: req.requestId
        });
      }
      res.json({
        ok: true,
        txHash: tx.hash,
        blockNumber: receipt.blockNumber,
        operation,
        events: parsed
      });
    } catch (error) {
      const code = error.code ?? "RELAY_FAILED";
      const short = error?.info?.error?.message ?? error?.shortMessage;
      log("error", "relay failed", {
        err: String(error.message ?? error),
        short,
        requestId: req.requestId
      });
      sendError(res, 400, code, String(error.message ?? error), short ? { short } : undefined);
    }
  }

  app.get("/v1/health", async (_req, res) => {
    const chain = await provider.getNetwork();
    const blockNumber = await provider.getBlockNumber();
    res.json({
      ok: true,
      service: "stoex-gasless-relayer",
      version: "1",
      chainId: Number(chain.chainId),
      blockNumber,
      relayer: wallet.address,
      forwarder: cfg.forwarder,
      forwarderEip712Name: cfg.forwarderEip712Name,
      tradeManager: tradeManagerAddr,
      authRequired: Boolean(cfg.apiKey)
    });
  });

  app.get("/v1/operations", (_req, res) => {
    res.json(cfg.operations.operations ?? {});
  });

  app.post("/v1/precheck/buy", async (req, res) => {
    try {
      const from = req.body?.from;
      if (!from) {
        sendError(res, 400, "INVALID_BODY", "from is required");
        return;
      }
      const result = await precheckBuy(precheckTm, from, req.body);
      res.json(result);
    } catch (error) {
      sendError(res, 400, error.code ?? "PRECHECK_FAILED", String(error.message ?? error));
    }
  });

  app.post("/v1/precheck/sell", async (req, res) => {
    try {
      const from = req.body?.from;
      if (!from) {
        sendError(res, 400, "INVALID_BODY", "from is required");
        return;
      }
      const result = await precheckSell(precheckTm, from, req.body);
      res.json(result);
    } catch (error) {
      sendError(res, 400, error.code ?? "PRECHECK_FAILED", String(error.message ?? error));
    }
  });

  app.post("/v1/precheck/redeem", async (req, res) => {
    try {
      const from = req.body?.from;
      if (!from) {
        sendError(res, 400, "INVALID_BODY", "from is required");
        return;
      }
      const result = await precheckRedeem(precheckTm, from, req.body);
      res.json(result);
    } catch (error) {
      sendError(res, 400, error.code ?? "PRECHECK_FAILED", String(error.message ?? error));
    }
  });

  app.post("/v1/precheck/raw", async (req, res) => {
    try {
      const { operation, args } = req.body ?? {};
      if (!operation) {
        sendError(res, 400, "INVALID_BODY", "operation is required");
        return;
      }
      const { to, data } = await precheckRaw({ config: cfg.operations, operation, args: coerceArgsArray(args) });
      res.json({ ok: true, to, data });
    } catch (error) {
      sendError(res, 400, error.code ?? "PRECHECK_FAILED", String(error.message ?? error));
    }
  });

  app.post("/v1/meta-tx/typed-data", metaTxTypedDataHandler);
  app.post("/v1/meta-tx/relay", metaTxRelayHandler);

  app.use((_req, res) => {
    sendError(res, 404, "NOT_FOUND", "Not found");
  });

  return app;
}
