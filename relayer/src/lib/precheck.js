import { ethers } from "ethers";
import { buildCallData, getOperation, normalizeAddress } from "./forwarder.js";

const tradeManagerPrecheckAbi = [
  "function createBuyRequest(uint256 weightMg,uint256 fiat_value,bytes32 payment_ref,bytes32 txDetailsHash) returns (uint256)",
  "function createSellRequest(uint256 grams,bytes32 payoutRefId) returns (uint256)",
  "function createRedeemRequest(uint256 grams,bytes32 deliveryRefId) returns (uint256)"
];

export function createPrecheckContract(tradeManagerAddress, provider) {
  return new ethers.Contract(tradeManagerAddress, tradeManagerPrecheckAbi, provider);
}

function toBytes32(v) {
  if (v == null || v === "") return ethers.ZeroHash;
  if (typeof v === "string" && v.startsWith("0x") && v.length === 66) return v;
  return ethers.encodeBytes32String(String(v));
}

function toU256(v) {
  try {
    return ethers.toBigInt(v);
  } catch {
    const err = new Error("Invalid uint256 value");
    err.code = "INVALID_ARG";
    throw err;
  }
}

export async function precheckBuy(tm, from, body) {
  const weightMg = toU256(body.weightMg);
  const fiatValue = toU256(body.fiatValue);
  const paymentRef = toBytes32(body.paymentRef ?? body.payment_ref);
  const txDetailsHash =
    body.txDetailsHash && String(body.txDetailsHash).startsWith("0x") && body.txDetailsHash.length === 66
      ? body.txDetailsHash
      : ethers.ZeroHash;
  const requestId = await tm.createBuyRequest.staticCall(weightMg, fiatValue, paymentRef, txDetailsHash, {
    from: normalizeAddress(from)
  });
  return { ok: true, requestId: requestId.toString() };
}

export async function precheckSell(tm, from, body) {
  const grams = toU256(body.grams);
  const payoutRefId = toBytes32(body.payoutRefId ?? body.payout_ref);
  const requestId = await tm.createSellRequest.staticCall(grams, payoutRefId, { from: normalizeAddress(from) });
  return { ok: true, requestId: requestId.toString() };
}

export async function precheckRedeem(tm, from, body) {
  const grams = toU256(body.grams);
  const deliveryRefId = toBytes32(body.deliveryRefId ?? body.delivery_ref);
  const requestId = await tm.createRedeemRequest.staticCall(grams, deliveryRefId, {
    from: normalizeAddress(from)
  });
  return { ok: true, requestId: requestId.toString() };
}

/**
 * Dry-run the same calldata the forwarder would send (does not enforce USER_ROLE / forwarder context).
 * Use user-flow prechecks for initiator-sensitive checks.
 */
export async function precheckRaw({ config, operation, args }) {
  const op = getOperation(config, operation);
  const toRaw = config.contracts?.[op.target];
  if (!toRaw) {
    const err = new Error(`Missing target address for ${op.target}`);
    err.code = "CONFIG_TARGET";
    throw err;
  }
  const to = normalizeAddress(toRaw);
  const data = buildCallData(op, args);
  return { to, data };
}
