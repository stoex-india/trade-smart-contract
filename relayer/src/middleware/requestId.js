import { randomBytes } from "node:crypto";

export function requestIdMiddleware(req, res, next) {
  const headerId = req.get("x-request-id");
  const id = headerId && headerId.length < 200 ? headerId : randomBytes(8).toString("hex");
  req.requestId = id;
  res.setHeader("x-request-id", id);
  next();
}
