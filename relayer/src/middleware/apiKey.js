export function apiKeyMiddleware(expectedKey) {
  if (!expectedKey) {
    return (_req, _res, next) => next();
  }
  return (req, res, next) => {
    const key = req.get("x-api-key") ?? req.get("authorization")?.replace(/^Bearer\s+/i, "");
    if (key !== expectedKey) {
      res.status(401).json({
        error: { code: "UNAUTHORIZED", message: "Invalid or missing API key" }
      });
      return;
    }
    next();
  };
}
