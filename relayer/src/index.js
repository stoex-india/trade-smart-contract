import "dotenv/config";
import fs from "node:fs";
import path from "node:path";
import express from "express";
import { ethers } from "ethers";

const PORT = Number(process.env.PORT ?? "8787");
const RPC_URL = process.env.RPC_URL;
const RELAYER_PRIVATE_KEY = process.env.RELAYER_PRIVATE_KEY;
const FORWARDER = process.env.ERC2771_FORWARDER;
const OPERATIONS_CONFIG = process.env.OPERATIONS_CONFIG ?? "./config/operations.example.json";

if (!RPC_URL || !RELAYER_PRIVATE_KEY || !FORWARDER) {
  throw new Error("Missing RPC_URL, RELAYER_PRIVATE_KEY or ERC2771_FORWARDER");
}

const configPath = path.isAbsolute(OPERATIONS_CONFIG)
  ? OPERATIONS_CONFIG
  : path.resolve(process.cwd(), OPERATIONS_CONFIG);
const config = JSON.parse(fs.readFileSync(configPath, "utf8"));

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(RELAYER_PRIVATE_KEY, provider);

const forwarderAbi = [
  "function nonces(address) view returns (uint256)",
  "function verify((address from,address to,uint256 value,uint256 gas,uint48 deadline,bytes data,bytes signature) request) view returns (bool)",
  "function execute((address from,address to,uint256 value,uint256 gas,uint48 deadline,bytes data,bytes signature) request) payable"
];
const forwarder = new ethers.Contract(FORWARDER, forwarderAbi, wallet);

const app = express();
app.use(express.json({ limit: "1mb" }));

function getOp(operation) {
  const op = config.operations?.[operation];
  if (!op) throw new Error(`Unknown operation: ${operation}`);
  if (!op.enabled) throw new Error(`Operation disabled: ${operation}`);
  return op;
}

function normalize(addr) {
  return ethers.getAddress(addr);
}

function ensureAllowedSigner(op, from) {
  if (!op.allowedSigners || op.allowedSigners.length === 0) return;
  const allow = new Set(op.allowedSigners.map((a) => normalize(a)));
  if (!allow.has(normalize(from))) {
    throw new Error("Signer not allowed for operation");
  }
}

function buildCallData(op, args) {
  const iface = new ethers.Interface([op.fragment]);
  const frag = iface.fragments[0];
  return iface.encodeFunctionData(frag.name, args ?? []);
}

async function buildRequestBody(operation, from, args, deadlineSeconds) {
  const op = getOp(operation);
  ensureAllowedSigner(op, from);
  const to = config.contracts?.[op.target];
  if (!to) throw new Error(`Missing target address for ${op.target}`);
  const data = buildCallData(op, args);
  const nonce = await forwarder.nonces(from);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + (deadlineSeconds ?? 900));

  return {
    from,
    to,
    value: 0n,
    gas: BigInt(op.gas ?? 700000),
    nonce,
    deadline,
    data
  };
}

app.get("/health", async (_req, res) => {
  const chain = await provider.getNetwork();
  res.json({
    ok: true,
    chainId: Number(chain.chainId),
    relayer: wallet.address,
    forwarder: FORWARDER
  });
});

app.get("/operations", (_req, res) => {
  res.json(config.operations ?? {});
});

app.post("/typed-data", async (req, res) => {
  try {
    const { operation, from, args, deadlineSeconds } = req.body;
    if (!operation || !from) throw new Error("operation and from are required");

    const request = await buildRequestBody(operation, normalize(from), args, deadlineSeconds);
    const chain = await provider.getNetwork();

    const domain = {
      name: "STOEX Forwarder",
      version: "1",
      chainId: Number(chain.chainId),
      verifyingContract: FORWARDER
    };
    const types = {
      ForwardRequest: [
        { name: "from", type: "address" },
        { name: "to", type: "address" },
        { name: "value", type: "uint256" },
        { name: "gas", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint48" },
        { name: "data", type: "bytes" }
      ]
    };
    const message = {
      from: request.from,
      to: request.to,
      value: request.value.toString(),
      gas: request.gas.toString(),
      nonce: request.nonce.toString(),
      deadline: request.deadline.toString(),
      data: request.data
    };

    res.json({ operation, domain, types, message });
  } catch (error) {
    res.status(400).json({ error: String(error.message ?? error) });
  }
});

app.post("/relay", async (req, res) => {
  try {
    const { operation, from, args, deadlineSeconds, signature } = req.body;
    if (!operation || !from || !signature) throw new Error("operation, from, signature are required");

    const request = await buildRequestBody(operation, normalize(from), args, deadlineSeconds);
    const forwardReq = {
      from: request.from,
      to: request.to,
      value: request.value,
      gas: request.gas,
      deadline: request.deadline,
      data: request.data,
      signature
    };

    const ok = await forwarder.verify(forwardReq);
    if (!ok) throw new Error("Forwarder verify() failed");

    const tx = await forwarder.execute(forwardReq, { value: 0 });
    const receipt = await tx.wait();
    res.json({
      ok: true,
      txHash: tx.hash,
      blockNumber: receipt.blockNumber,
      operation
    });
  } catch (error) {
    res.status(400).json({ error: String(error.message ?? error) });
  }
});

app.listen(PORT, () => {
  console.log(`Gasless relayer listening on :${PORT}`);
  console.log(`Relayer address: ${wallet.address}`);
});
