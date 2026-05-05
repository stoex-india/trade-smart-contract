import { ethers } from "ethers";

const forwarderIface = new ethers.Interface([
  "event ExecutedForwardRequest(address indexed signer, uint256 nonce, bool success)"
]);

const tradeIface = new ethers.Interface([
  "event RequestCreated(uint256 indexed requestId, uint8 requestType, address indexed initiator, uint256 grams, uint256 fiatValue)"
]);

export function parseRelayReceipt(receipt, { tradeManagerAddress }) {
  const out = {
    forward: null,
    requestCreated: null
  };
  const tm = tradeManagerAddress ? ethers.getAddress(tradeManagerAddress) : null;

  for (const log of receipt.logs) {
    try {
      const parsed = forwarderIface.parseLog(log);
      if (parsed?.name === "ExecutedForwardRequest") {
        out.forward = {
          signer: parsed.args.signer,
          nonce: parsed.args.nonce.toString(),
          success: parsed.args.success
        };
      }
    } catch {
      // ignore
    }
    if (tm && log.address.toLowerCase() === tm.toLowerCase()) {
      try {
        const parsed = tradeIface.parseLog(log);
        if (parsed?.name === "RequestCreated") {
          out.requestCreated = {
            requestId: parsed.args.requestId.toString(),
            requestType: Number(parsed.args.requestType),
            initiator: parsed.args.initiator,
            grams: parsed.args.grams.toString(),
            fiatValue: parsed.args.fiatValue.toString()
          };
        }
      } catch {
        // ignore
      }
    }
  }
  return out;
}
