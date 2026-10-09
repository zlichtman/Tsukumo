// The relay's only logging. It takes a fixed set of fields, never a body, a header, a path,
// or a query string, so nothing a caller or the Mac sends can end up in Cloudflare's logs.

export interface LogFields {
  device?: string;
  status?: number;
  ms?: number;
  method?: string;
  reason?: string;
  code?: number;
}

const ALLOWED_REASON = /^[a-z_]{1,40}$/;

export function log(event: string, fields: LogFields = {}): void {
  const line: Record<string, string | number> = { event };
  // A device id is unguessable on purpose, so only its first characters are ever logged.
  if (fields.device) line.device = fields.device.slice(0, 6);
  if (typeof fields.status === "number") line.status = fields.status;
  if (typeof fields.ms === "number") line.ms = Math.round(fields.ms);
  if (fields.method && /^[A-Z]{3,7}$/.test(fields.method)) line.method = fields.method;
  if (fields.reason && ALLOWED_REASON.test(fields.reason)) line.reason = fields.reason;
  if (typeof fields.code === "number") line.code = fields.code;
  console.log(JSON.stringify(line));
}
