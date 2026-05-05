import { ethers } from "ethers";

const forwarderAbi = [
  "function nonces(address) view returns (uint256)",
  "function verify((address from,address to,uint256 value,uint256 gas,uint48 deadline,bytes data,bytes signature) request) view returns (bool)",
  "function execute((address from,address to,uint256 value,uint256 gas,uint48 deadline,bytes data,bytes signature) request) payable",
  "event ExecutedForwardRequest(address indexed signer, uint256 nonce, bool success)"
];

export function createForwarderContract(address, runner) {
  return new ethers.Contract(address, forwarderAbi, runner);
}

export function normalizeAddress(addr) {
  return ethers.getAddress(addr);
}

export function getOperation(config, operation) {
  const op = config.operations?.[operation];
  if (!op) {
    const err = new Error(`Unknown operation: ${operation}`);
    err.code = "UNKNOWN_OPERATION";
    throw err;
  }
  if (!op.enabled) {
    const err = new Error(`Operation disabled: ${operation}`);
    err.code = "OPERATION_DISABLED";
    throw err;
  }
  return op;
}

export function ensureAllowedSigner(op, from) {
  if (!op.allowedSigners || op.allowedSigners.length === 0) return;
  const allow = new Set(op.allowedSigners.map((a) => normalizeAddress(a)));
  if (!allow.has(normalizeAddress(from))) {
    const err = new Error("Signer not allowed for this operation");
    err.code = "SIGNER_NOT_ALLOWED";
    throw err;
  }
}

export function buildCallData(op, args) {
  const iface = new ethers.Interface([op.fragment]);
  const frag = iface.fragments[0];
  return iface.encodeFunctionData(frag.name, args ?? []);
}

export async function buildMetaTxRequest({ config, forwarder, operation, from, args, deadlineSeconds }) {
  const op = getOperation(config, operation);
  ensureAllowedSigner(op, from);
  const toRaw = config.contracts?.[op.target];
  if (!toRaw) {
    const err = new Error(`Missing target address for ${op.target}`);
    err.code = "CONFIG_TARGET";
    throw err;
  }
  const to = normalizeAddress(toRaw);
  const data = buildCallData(op, args);
  const nonce = await forwarder.nonces(from);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + (deadlineSeconds ?? 900));

  return {
    from,
    to,
    value: 0n,
    gas: BigInt(op.gas ?? 700_000),
    nonce,
    deadline,
    data
  };
}

export function eip712TypedData({ chainId, verifyingContract, name, version, request }) {
  const domain = {
    name,
    version,
    chainId,
    verifyingContract
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
  return { domain, types, message };
}

export function toForwardRequestData(request, signature) {
  return {
    from: request.from,
    to: request.to,
    value: request.value,
    gas: request.gas,
    deadline: request.deadline,
    data: request.data,
    signature
  };
}
