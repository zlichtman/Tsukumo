// The Tsukumo relay's wire format and the rules both sides of it share.
// The envelope spec the Mac client implements is in docs/ARCHITECTURE.md ("The envelope").

export const PROTOCOL = "tsukumo-relay-v1";

/** A device id: 128 random bits as lowercase RFC 4648 base32 with no padding (26 characters). */
export const DEVICE_ID_PATTERN = /^[a-z2-7]{26}$/;

const KiB = 1024;
const MiB = 1024 * KiB;

export const LIMITS = {
  /** Largest public request body (the gateway's 10 MB file default plus overhead). Bodies are streamed, never held whole. */
  maxRequestBytes: 12 * MiB,
  /** Largest response the relay will carry for one request, streamed or not. */
  maxResponseBytes: 100 * MiB,
  /** A request body at most this big (with a Content-Length) goes inline in its `req` frame; anything else is streamed. */
  inlineRequestBytes: 256 * KiB,
  /** Largest decoded `chunk` either way, and largest inline `res` body. */
  maxChunkBytes: 256 * KiB,
  /** Body bytes either side may have sent for one request and not yet had acknowledged. */
  flowWindowBytes: 1 * MiB,
  /** Largest text frame from a live socket, checked before it is parsed (a 256 KiB chunk in base64 plus room). */
  maxFrameChars: 400 * KiB,
  /** Bytes of bodies the relay may hold in memory at once, across every device in this isolate (whose limit is 128 MB). */
  memoryBudgetBytes: 48 * MiB,
  maxPathLength: 2048,
  maxQueryLength: 8192,
  maxHeaderCount: 100,
  maxHeaderBytes: 32 * KiB,
  /** How long a challenge's nonce stays good. */
  nonceLifetimeMs: 30_000,
} as const;

export const ALLOWED_METHODS = new Set(["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]);

export type Mode = "register" | "connect";

// Frames the relay sends to the Mac.
export interface ReadyFrame { type: "ready"; device_id: string; public_base: string; registered: boolean }
export interface RequestFrame {
  type: "req";
  id: string;
  method: string;
  path: string;
  query: string;
  headers: [string, string][];
  body_b64: string;
  body_stream?: true;
}
export interface CancelFrame { type: "cancel"; id: string }
export interface AckFrame { type: "ack"; id: string; bytes: number }
export interface ChunkFrame { type: "chunk"; id: string; data_b64: string }
export interface EndFrame { type: "end"; id: string }

/** What the device signs: domain-separated, bound to the mode, the device id, and the relay's single-use nonce. */
export function authMessage(mode: Mode, deviceId: string, nonce: string): string {
  return `${PROTOCOL}\nauth\n${mode}\n${deviceId}\n${nonce}`;
}

/** The largest decoded size a base64 string of this length can have, so limits are checked before decoding. */
export function decodedLength(b64: string): number {
  const padding = b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0;
  return Math.floor((b64.length * 3) / 4) - padding;
}

/**
 * Headers on every answer from a public URL. The sandbox gives any page an opaque origin (no
 * cookies, storage, or service workers), so a page served for one device can't reach another's.
 * `allow-scripts` is there because a sandbox without it also stops `<meta http-equiv="refresh">`
 * (the "automatic features" flag), and the gateway's sign-in wait page refreshes that way; a script
 * in an opaque origin can't read anything of another device's. `allow-forms` keeps a form working,
 * and `allow-top-navigation-by-user-activation` lets a link leave a framed page only when clicked.
 */
export const SECURITY_HEADERS: [string, string][] = [
  ["content-security-policy", "sandbox allow-forms allow-scripts allow-top-navigation-by-user-activation"],
  ["x-content-type-options", "nosniff"],
  ["referrer-policy", "no-referrer"],
  ["cross-origin-opener-policy", "same-origin"],
  ["x-frame-options", "DENY"],
];

// Hop-by-hop headers (RFC 9110 section 7.6.1) and ones the relay sets itself or never passes on.
const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "proxy-connection",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

const DROPPED_REQUEST = new Set([
  ...HOP_BY_HOP,
  "content-length",
  "host",
  // The Mac answers uncompressed; Cloudflare compresses toward the client itself.
  "accept-encoding",
  "forwarded",
  "x-forwarded-for",
  "x-forwarded-proto",
  "x-forwarded-host",
  "x-real-ip",
  "true-client-ip",
  "cdn-loop",
  "service-worker",
]);

// Besides hop-by-hop headers: anything that could reach past one device on a shared origin
// (cookies with Path=/, Clear-Site-Data, a service worker's widened scope) and the headers the
// relay sets itself.
const DROPPED_RESPONSE = new Set([
  ...HOP_BY_HOP,
  "content-length",
  "alt-svc",
  "strict-transport-security",
  "set-cookie",
  "set-cookie2",
  "clear-site-data",
  "service-worker-allowed",
  ...SECURITY_HEADERS.filter(([n]) => n !== "content-security-policy").map(([n]) => n),
]);

function connectionTokens(headers: Headers): Set<string> {
  const listed = headers.get("connection") ?? "";
  return new Set(listed.split(",").map((t) => t.trim().toLowerCase()).filter(Boolean));
}

/**
 * The public request's headers as the Mac sees them: hop-by-hop headers, Cloudflare's own,
 * and anything a client could use to spoof the relay's headers are dropped, then the relay's
 * forwarding headers are set.
 */
export function forwardedRequestHeaders(
  incoming: Headers,
  info: { host: string; clientIP: string; proto: string; publicBase: string },
): [string, string][] {
  const named = connectionTokens(incoming);
  const out: [string, string][] = [];
  incoming.forEach((value, rawName) => {
    const name = rawName.toLowerCase();
    if (DROPPED_REQUEST.has(name) || named.has(name)) return;
    if (name.startsWith("cf-") || name.startsWith("x-tsukumo-") || name.startsWith("x-relay-")) return;
    out.push([name, value]);
  });
  out.push(["host", info.host]);
  out.push(["x-forwarded-for", info.clientIP]);
  out.push(["x-forwarded-proto", info.proto]);
  out.push(["x-forwarded-host", info.host]);
  out.push(["x-tsukumo-public-base", info.publicBase]);
  return out;
}

const TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;
const BAD_VALUE = /[\0\r\n]/;

/**
 * The Mac's response headers as the public client sees them. Hop-by-hop headers and CORS are
 * dropped (the relay serves server-to-server clients; no browser should read these answers).
 * Returns null when the headers are malformed.
 */
export function publicResponseHeaders(pairs: unknown): Headers | null {
  if (!Array.isArray(pairs) || pairs.length > LIMITS.maxHeaderCount) return null;
  const headers = new Headers();
  const pending: [string, string][] = [];
  let bytes = 0;
  for (const pair of pairs) {
    if (!Array.isArray(pair) || pair.length !== 2) return null;
    const [name, value] = pair;
    if (typeof name !== "string" || typeof value !== "string") return null;
    bytes += name.length + value.length + 4;
    if (bytes > LIMITS.maxHeaderBytes) return null;
    if (!TOKEN.test(name) || BAD_VALUE.test(value)) return null;
    pending.push([name.toLowerCase(), value]);
  }
  const named = new Set<string>();
  for (const [name, value] of pending) {
    if (name === "connection") value.split(",").forEach((t) => named.add(t.trim().toLowerCase()));
  }
  for (const [name, value] of pending) {
    if (DROPPED_RESPONSE.has(name) || named.has(name)) continue;
    if (name.startsWith("access-control-")) continue;
    headers.append(name, value);
  }
  headers.set("cache-control", headers.get("cache-control") ?? "no-store");
  addSecurityHeaders(headers);
  return headers;
}

/** Adds the relay's security headers. A policy the Mac sent stays too (both are enforced). */
export function addSecurityHeaders(headers: Headers): void {
  for (const [name, value] of SECURITY_HEADERS) {
    if (name === "content-security-policy") headers.append(name, value);
    else headers.set(name, value);
  }
}

/** Checks the path the device will see. Dot segments are already gone (URL parsing resolves them). */
export function validForwardPath(path: string, query: string): boolean {
  if (!path.startsWith("/") || path.length > LIMITS.maxPathLength) return false;
  if (query.length > LIMITS.maxQueryLength) return false;
  if (path.includes("//") || path.includes("\\")) return false;
  // Encoded separators, dots, NUL, and percent-encoded control characters never reach the Mac.
  if (/%(2f|5c|2e|00|0[0-9a-f]|1[0-9a-f]|7f)/i.test(path)) return false;
  if (/[\u0000-\u001f\u007f]/.test(path + query)) return false;
  return true;
}

export function headerBudgetOK(headers: Headers): boolean {
  let count = 0;
  let bytes = 0;
  headers.forEach((value, name) => {
    count += 1;
    bytes += name.length + value.length + 4;
  });
  return count <= LIMITS.maxHeaderCount && bytes <= LIMITS.maxHeaderBytes;
}

// Base64, chunked so large bodies don't blow the argument limit of String.fromCharCode.
export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  const step = 0x8000;
  for (let i = 0; i < bytes.length; i += step) {
    binary += String.fromCharCode(...bytes.subarray(i, i + step));
  }
  return btoa(binary);
}

export function fromBase64(text: string): Uint8Array | null {
  try {
    const binary = atob(text);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

export function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64Url(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return null;
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  return fromBase64(padded);
}

const BASE32 = "abcdefghijklmnopqrstuvwxyz234567";

export function base32(bytes: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 31];
  return out;
}

export function newDeviceId(): string {
  return base32(crypto.getRandomValues(new Uint8Array(16)));
}

// A challenge's nonce is stateless: 8 bytes of issue time (ms, big endian), 16 random bytes, and an
// HMAC-SHA-256 over the mode, the device id, and both, with a key the device's object keeps only in
// memory. So answering challenges holds no slot open, and a flood of challenges can't crowd out
// the real device. Single use comes from the device record: a connect's nonce must be newer than
// the last one accepted.

const enc = new TextEncoder();

async function nonceMac(key: CryptoKey, mode: Mode, deviceId: string, body: Uint8Array): Promise<Uint8Array> {
  const label = enc.encode(`${PROTOCOL}\nnonce\n${mode}\n${deviceId}\n`);
  const data = new Uint8Array(label.length + body.length);
  data.set(label);
  data.set(body, label.length);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, data));
}

export async function newNonce(key: CryptoKey, mode: Mode, deviceId: string, now = Date.now()): Promise<string> {
  const body = new Uint8Array(24);
  new DataView(body.buffer).setBigUint64(0, BigInt(now));
  body.set(crypto.getRandomValues(new Uint8Array(16)), 8);
  const mac = await nonceMac(key, mode, deviceId, body);
  const out = new Uint8Array(56);
  out.set(body);
  out.set(mac, 24);
  return toBase64Url(out);
}

/** The nonce's issue time when it is genuine, for this mode and device, and still fresh; otherwise null. */
export async function checkNonce(key: CryptoKey, mode: Mode, deviceId: string, nonce: string, now = Date.now()): Promise<number | null> {
  if (nonce.length > 100) return null;
  const raw = fromBase64Url(nonce);
  if (!raw || raw.length !== 56) return null;
  const body = raw.subarray(0, 24);
  const expected = await nonceMac(key, mode, deviceId, body);
  let diff = 0;
  for (let i = 0; i < 32; i++) diff |= expected[i] ^ raw[24 + i];
  if (diff !== 0) return null;
  const issued = Number(new DataView(body.buffer, body.byteOffset, 8).getBigUint64(0));
  if (issued > now + 1000 || now - issued > LIMITS.nonceLifetimeMs) return null;
  return issued;
}

/** Verifies an ECDSA P-256 / SHA-256 signature in raw r||s form (CryptoKit's rawRepresentation). */
export async function verifyDeviceSignature(publicKeyB64Url: string, message: string, signatureB64Url: string): Promise<boolean> {
  if (publicKeyB64Url.length > 100 || signatureB64Url.length > 100) return false;
  const key = fromBase64Url(publicKeyB64Url);
  const signature = fromBase64Url(signatureB64Url);
  if (!key || key.length !== 65 || key[0] !== 0x04 || !signature || signature.length !== 64) return false;
  try {
    const imported = await crypto.subtle.importKey("raw", key, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, imported, signature, new TextEncoder().encode(message));
  } catch {
    return false;
  }
}

export function jsonError(status: number, error: string, message: string, extra: Record<string, string> = {}): Response {
  const headers = new Headers({ "content-type": "application/json", "cache-control": "no-store", ...extra });
  addSecurityHeaders(headers);
  return new Response(JSON.stringify({ error, message }), { status, headers });
}

export const notFound = () => jsonError(404, "not_found", "Nothing is here.");
