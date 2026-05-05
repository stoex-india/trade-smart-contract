import "dotenv/config";
import { ethers } from "ethers";

const RELAYER_BASE_URL = process.env.RELAYER_BASE_URL ?? "http://127.0.0.1:8787";
const RPC_URL = process.env.RPC_URL;
const TRADE_MANAGER = process.env.TRADE_MANAGER;

if (!RPC_URL || !TRADE_MANAGER) {
  throw new Error("Missing RPC_URL or TRADE_MANAGER in relayer .env");
}

const provider = new ethers.JsonRpcProvider(RPC_URL);

const adminSigner = new ethers.Wallet(process.env.ADMIN_PRIVATE_KEY ?? process.env.RELAYER_PRIVATE_KEY, provider);
const apSigner = new ethers.Wallet(process.env.AP_PRIVATE_KEY ?? process.env.ADMIN_PRIVATE_KEY, provider);
const vpSigner = new ethers.Wallet(process.env.VP_PRIVATE_KEY ?? process.env.ADMIN_PRIVATE_KEY, provider);
const atSigner = new ethers.Wallet(process.env.AT_PRIVATE_KEY ?? process.env.ADMIN_PRIVATE_KEY, provider);
const papSigner = new ethers.Wallet(process.env.PAP_PRIVATE_KEY ?? process.env.ADMIN_PRIVATE_KEY, provider);
const userSigner = new ethers.Wallet(process.env.USER_PRIVATE_KEY, provider);

if (!process.env.USER_PRIVATE_KEY) {
  throw new Error("Missing USER_PRIVATE_KEY for gasless user-initiated operations");
}

const tradeAbi = [
  "event RequestCreated(uint256 indexed requestId, uint8 requestType, address indexed initiator, uint256 grams, uint256 fiatValue)",
  "function approveRequest(uint256 requestId)",
  "function executeRequest(uint256 requestId)",
  "function getRequestStatus(uint256 requestId) view returns (uint8)",
  "function coSignNonce(uint256 requestId) view returns (uint256)",
  "function hashCoSignBatch(uint256 requestId,uint256 nonce,uint256 deadline) view returns (bytes32)",
  "function executeWithCoSignatures(uint256 requestId,uint256 nonce,uint256 deadline,bytes[] signatures)"
];
const tradeAdmin = new ethers.Contract(TRADE_MANAGER, tradeAbi, adminSigner);
const tradeIface = new ethers.Interface(tradeAbi);

function toBytes32(v, fallback) {
  const value = v ?? fallback;
  if (!value) throw new Error("bytes32 value is required");
  if (value.startsWith("0x")) return value;
  return ethers.encodeBytes32String(value);
}

async function relayerCall(path, body) {
  const headers = { "content-type": "application/json" };
  if (process.env.RELAYER_API_KEY) {
    headers["x-api-key"] = process.env.RELAYER_API_KEY;
  }
  const res = await fetch(`${RELAYER_BASE_URL}${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body)
  });
  const json = await res.json();
  if (!res.ok) {
    const msg =
      typeof json.error === "object" && json.error?.message != null
        ? json.error.message
        : json.error ?? res.statusText;
    throw new Error(`Relayer ${path} failed: ${msg}`);
  }
  return json;
}

async function relayMetaTx(operation, signer, args) {
  const from = await signer.getAddress();
  const typed = await relayerCall(`/v1/meta-tx/typed-data`, { operation, from, args });
  const signature = await signer.signTypedData(typed.domain, typed.types, typed.message);
  const relayed = await relayerCall(`/v1/meta-tx/relay`, { operation, from, args, signature });
  return relayed.txHash;
}

async function waitRequestId(txHash) {
  const receipt = await provider.waitForTransaction(txHash, 1, 120_000);
  if (!receipt) throw new Error(`No receipt for tx ${txHash}`);
  for (const log of receipt.logs) {
    try {
      const parsed = tradeIface.parseLog(log);
      if (parsed?.name === "RequestCreated") return parsed.args.requestId;
    } catch {
      // Ignore non-TradeManager logs.
    }
  }
  throw new Error(`RequestCreated not found in tx ${txHash}`);
}

async function approveAndExecute(requestId, rolesInOrder) {
  for (const role of rolesInOrder) {
    const signer = role === "AP" ? apSigner : role === "VP" ? vpSigner : role === "PAP" ? papSigner : atSigner;
    const tx = await new ethers.Contract(TRADE_MANAGER, tradeAbi, signer).approveRequest(requestId);
    await tx.wait();
  }
  const exec = await tradeAdmin.executeRequest(requestId);
  await exec.wait();
  const status = await tradeAdmin.getRequestStatus(requestId);
  if (Number(status) !== 5) throw new Error(`Request ${requestId} not Executed. Status=${status}`);
}

async function runBuy() {
  const weightMg = BigInt(process.env.BUY_WEIGHT_MG ?? process.env.BUY_GRAMS ?? "100000");
  const fiatValue = BigInt(process.env.BUY_FIAT_VALUE ?? "1");
  const paymentRef = toBytes32(process.env.BUY_PAYMENT_REF, "BUY-REF-001");
  const txDetailsHash =
    process.env.BUY_TX_DETAILS_HASH && process.env.BUY_TX_DETAILS_HASH.startsWith("0x")
      ? process.env.BUY_TX_DETAILS_HASH
      : ethers.ZeroHash;
  const txHash = await relayMetaTx("buy", userSigner, [
    weightMg.toString(),
    fiatValue.toString(),
    paymentRef,
    txDetailsHash
  ]);
  await provider.waitForTransaction(txHash, 1, 120_000);
  const requestId = await waitRequestId(txHash);
  const status = await tradeAdmin.getRequestStatus(requestId);
  if (Number(status) !== 5) throw new Error(`Buy request ${requestId} not Executed (status=${status})`);
  return { flow: "buy", requestId: requestId.toString(), txHash };
}

async function runSell() {
  const grams = BigInt(process.env.SELL_GRAMS ?? "500");
  const payoutRef = toBytes32(process.env.SELL_PAYOUT_REF, "SELL-REF-001");
  const txHash = await relayMetaTx("sell", userSigner, [grams.toString(), payoutRef]);
  const requestId = await waitRequestId(txHash);
  await approveAndExecute(requestId, ["AP", "AT"]);
  return { flow: "sell", requestId: requestId.toString(), txHash };
}

async function runRedeem() {
  const grams = BigInt(process.env.REDEEM_GRAMS ?? "1000");
  const deliveryRef = toBytes32(process.env.REDEEM_DELIVERY_REF, "REDEEM-REF-001");
  const txHash = await relayMetaTx("redeem", userSigner, [grams.toString(), deliveryRef]);
  const requestId = await waitRequestId(txHash);
  await approveAndExecute(requestId, ["AP", "VP", "PAP", "AT"]);
  return { flow: "redeem", requestId: requestId.toString(), txHash };
}

async function runMint() {
  const grams = BigInt(process.env.MINT_GRAMS ?? "1000");
  const creditTo = process.env.MINT_CREDIT_TO ?? (await userSigner.getAddress());
  const vaultReceiptId = toBytes32(process.env.MINT_VAULT_RECEIPT_ID, "VAULT-RCPT-001");
  const lot = {
    vaultReceiptId,
    batchId: toBytes32(process.env.MINT_BATCH_ID, "BATCH-001"),
    purity: Number(process.env.MINT_PURITY ?? "999"),
    depositTimestamp: BigInt(process.env.MINT_DEPOSIT_TS ?? Math.floor(Date.now() / 1000).toString()),
    apId: process.env.MINT_AP_ID ?? (await apSigner.getAddress()),
    vpId: process.env.MINT_VP_ID ?? (await vpSigner.getAddress()),
    lockUntilTs: BigInt(process.env.MINT_LOCK_UNTIL_TS ?? "0"),
    grams
  };
  const apFromSigner = new ethers.Wallet(process.env.AP_PRIVATE_KEY ?? process.env.ADMIN_PRIVATE_KEY, provider);
  const txHash = await relayMetaTx("mint", apFromSigner, [grams.toString(), creditTo, vaultReceiptId, lot]);
  const requestId = await waitRequestId(txHash);
  await approveAndExecute(requestId, ["VP", "AT"]);
  return { flow: "mint", requestId: requestId.toString(), txHash };
}

async function runBurn() {
  const grams = BigInt(process.env.BURN_GRAMS ?? "500");
  const refId = toBytes32(process.env.BURN_REF_ID, "BURN-REF-001");
  const reason = process.env.BURN_REASON ?? "Ops burn";
  const apFromSigner = new ethers.Wallet(process.env.AP_PRIVATE_KEY ?? process.env.ADMIN_PRIVATE_KEY, provider);
  const txHash = await relayMetaTx("burn", apFromSigner, [grams.toString(), refId, reason]);
  const requestId = await waitRequestId(txHash);
  await approveAndExecute(requestId, ["VP", "AT"]);
  return { flow: "burn", requestId: requestId.toString(), txHash };
}

const flowHandlers = { buy: runBuy, sell: runSell, redeem: runRedeem, mint: runMint, burn: runBurn };

async function main() {
  const flows = (process.env.GASLESS_FLOWS ?? "buy,sell,redeem,mint,burn")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  const parallel = String(process.env.GASLESS_PARALLEL ?? "false").toLowerCase() === "true";

  for (const f of flows) {
    if (!flowHandlers[f]) throw new Error(`Unsupported flow "${f}"`);
  }

  const chain = await provider.getNetwork();
  console.log(`Running gasless flows on chain ${chain.chainId} via ${RELAYER_BASE_URL}`);
  console.log(`Flows: ${flows.join(", ")} | parallel=${parallel}`);

  if (parallel) {
    const results = await Promise.all(flows.map((f) => flowHandlers[f]()));
    console.log("Gasless flow results:", results);
  } else {
    const results = [];
    for (const f of flows) {
      // eslint-disable-next-line no-await-in-loop
      results.push(await flowHandlers[f]());
    }
    console.log("Gasless flow results:", results);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
