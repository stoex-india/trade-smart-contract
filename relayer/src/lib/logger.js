export function log(level, msg, meta = undefined) {
  const line = {
    ts: new Date().toISOString(),
    level,
    msg,
    ...meta
  };
  const out = JSON.stringify(line);
  if (level === "error") console.error(out);
  else console.log(out);
}
