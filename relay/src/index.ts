// The Tsukumo relay: the Worker in front of every device's Durable Object.
//
//   GET https://<host>/challenge[?device=<id>]   a nonce to sign (no device: a new registration)
//   wss://<host>/connect?device=<id>            the Mac's one outbound socket, accepted once its signature checks out
//
// Public traffic for a device, in one of two forms:
//   https://<id>.<DEVICE_HOST_SUFFIX>/<path...> each device on its own origin (recommended, needs a wildcard domain)
//   https://<host>/d/<id>/<path...>             the path form (workers.dev), plus the RFC 9728 / RFC 8414
//   https://<host>/.well-known/<doc>/d/<id>…    path-inserted metadata URLs
//
// The Worker only routes and rate-limits by IP. Everything about a device lives in its Durable
// Object (src/device.ts). Authentication, consent, and policy stay on the Mac.

import { ALLOWED_METHODS, DEVICE_ID_PATTERN, addSecurityHeaders, headerBudgetOK, jsonError, newDeviceId, notFound, validForwardPath } from "./protocol";
import type { DeviceRelay } from "./device";
import type { Registry } from "./registry";
import { log } from "./log";

export { DeviceRelay } from "./device";
export { Registry } from "./registry";

export interface Env {
  DEVICE: DurableObjectNamespace<DeviceRelay>;
  REGISTRY: DurableObjectNamespace<Registry>;
  /** Per client IP, every public request, challenge, and connect. */
  IP_LIMITER?: RateLimit;
  /** Per client IP, new registration challenges. */
  REGISTER_LIMITER?: RateLimit;
  /** Per device and client IP, challenges (so one address can't spend another's). */
  CHALLENGE_LIMITER?: RateLimit;
  /** Optional: the origin the path form's public URLs are built on (https://relay.example). Defaults to the request's own. */
  PUBLIC_ORIGIN?: string;
  /** Optional: with a wildcard domain routed here, each device is served at https://<id>.<suffix> and the path form is off. */
  DEVICE_HOST_SUFFIX?: string;
  REQUEST_TIMEOUT_MS?: string;
  STREAM_IDLE_TIMEOUT_MS?: string;
  UPLOAD_IDLE_TIMEOUT_MS?: string;
  UPLOAD_TOTAL_TIMEOUT_MS?: string;
  DEVICE_REQUESTS_PER_MINUTE?: string;
  DEVICE_MAX_IN_FLIGHT?: string;
  LEASE_DAYS?: string;
  MAX_DEVICES?: string;
  REGISTRATIONS_PER_IP_PER_DAY?: string;
  /** How often the registry reconciles its count against the device objects. */
  RECONCILE_MINUTES?: string;
  /** Device objects asked per reconciliation step, and how many at once. */
  RECONCILE_BATCH?: string;
  RECONCILE_CONCURRENCY?: string;
}

// The .well-known documents MCP clients look up with the issuer's or resource's path inserted after them.
const WELL_KNOWN = new Set(["oauth-protected-resource", "oauth-authorization-server", "openid-configuration"]);

export interface Route {
  deviceId: string;
  path: string;
}

/** Maps a path-form public path to the device and the path its Mac sees, or null. */
export function routePublicPath(pathname: string): Route | null {
  // /d/<id> and /d/<id>/<rest>
  let m = /^\/d\/([^/]+)(\/.*)?$/.exec(pathname);
  if (m) return { deviceId: m[1], path: m[2] ?? "/" };
  // /.well-known/<doc>/d/<id> and /.well-known/<doc>/d/<id>/<rest>
  m = /^\/\.well-known\/([^/]+)\/d\/([^/]+)(\/.*)?$/.exec(pathname);
  if (m && WELL_KNOWN.has(m[1])) return { deviceId: m[2], path: `/.well-known/${m[1]}${m[3] ?? ""}` };
  return null;
}

function suffix(env: Env): string | null {
  const s = env.DEVICE_HOST_SUFFIX?.trim().toLowerCase().replace(/^\.+|\.+$/g, "");
  return s ? s : null;
}

/** The device a per-device hostname names, when per-device origins are on. */
export function deviceFromHost(host: string, hostSuffix: string | null): string | null {
  if (!hostSuffix) return null;
  const name = host.toLowerCase().replace(/:\d+$/, "");
  if (!name.endsWith(`.${hostSuffix}`)) return null;
  const label = name.slice(0, -hostSuffix.length - 1);
  return label.includes(".") ? "" : label;
}

function clientIP(request: Request): string {
  return request.headers.get("cf-connecting-ip") ?? "unknown";
}

function pathOrigin(env: Env, url: URL): string {
  return env.PUBLIC_ORIGIN?.replace(/\/+$/, "") || url.origin;
}

/** A device's public base: its own origin when per-device origins are on, else the path form. */
export function publicBase(env: Env, url: URL, deviceId: string): string {
  const s = suffix(env);
  return s ? `https://${deviceId}.${s}` : `${pathOrigin(env, url)}/d/${deviceId}`;
}

async function limited(limiter: RateLimit | undefined, key: string): Promise<boolean> {
  if (!limiter) return false;
  const { success } = await limiter.limit({ key });
  return !success;
}

const tooMany = () => jsonError(429, "rate_limited", "Too many requests. Try again shortly.", { "retry-after": "10" });

function stubFor(env: Env, deviceId: string) {
  return env.DEVICE.get(env.DEVICE.idFromName(deviceId));
}

async function relayRoutes(request: Request, env: Env, url: URL, ip: string): Promise<Response | null> {
  if (url.pathname === "/healthz") {
    const headers = new Headers({ "cache-control": "no-store" });
    addSecurityHeaders(headers);
    return new Response("ok\n", { headers });
  }

  if (url.pathname === "/challenge") {
    if (request.method !== "GET") return jsonError(405, "method_not_allowed", "Use GET.");
    if (await limited(env.IP_LIMITER, `ip:${ip}`)) return tooMany();
    const asked = url.searchParams.get("device");
    let deviceId: string;
    let mode: "register" | "connect";
    if (asked === null) {
      if (await limited(env.REGISTER_LIMITER, `register:${ip}`)) return tooMany();
      deviceId = newDeviceId();
      mode = "register";
    } else {
      if (!DEVICE_ID_PATTERN.test(asked)) return notFound();
      if (await limited(env.CHALLENGE_LIMITER, `challenge:${asked}:${ip}`)) return tooMany();
      deviceId = asked;
      mode = "connect";
    }
    const headers = new Headers({ "x-relay-mode": mode, "x-relay-device": deviceId });
    const answer = await stubFor(env, deviceId).fetch("https://device.internal/challenge", { headers });
    const out = new Response(answer.body, answer);
    addSecurityHeaders(out.headers);
    return out;
  }

  if (url.pathname === "/connect") {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return jsonError(426, "upgrade_required", "Connect with a WebSocket.", { upgrade: "websocket" });
    }
    if (await limited(env.IP_LIMITER, `ip:${ip}`)) return tooMany();
    const deviceId = url.searchParams.get("device") ?? "";
    if (!DEVICE_ID_PATTERN.test(deviceId)) return notFound();
    const headers = new Headers({
      upgrade: "websocket",
      "x-relay-device": deviceId,
      "x-relay-public-base": publicBase(env, url, deviceId),
      "x-relay-client-ip": ip,
    });
    for (const name of ["x-tsukumo-nonce", "x-tsukumo-signature", "x-tsukumo-public-key"]) {
      const value = request.headers.get(name);
      if (value !== null) headers.set(name, value.slice(0, 200));
    }
    return stubFor(env, deviceId).fetch("https://device.internal/connect", { headers });
  }
  return null;
}

async function forward(request: Request, env: Env, url: URL, ip: string, route: Route, host: string, base: string): Promise<Response> {
  if (!DEVICE_ID_PATTERN.test(route.deviceId)) return notFound();
  if (await limited(env.IP_LIMITER, `ip:${ip}`)) return tooMany();
  if (!ALLOWED_METHODS.has(request.method)) return jsonError(405, "method_not_allowed", "That method isn't supported.");
  // A service worker's script is never served: with one, a page could take over the origin.
  if (request.headers.has("service-worker")) return jsonError(403, "forbidden", "Service workers aren't served here.");
  const query = url.search.startsWith("?") ? url.search.slice(1) : url.search;
  if (!validForwardPath(route.path, query)) return jsonError(400, "bad_path", "That path isn't allowed.");
  if (!headerBudgetOK(request.headers)) return jsonError(431, "headers_too_large", "Too many or too large headers.");
  if (request.headers.get("upgrade")) return jsonError(400, "no_upgrade", "Upgrades aren't relayed.");

  // A fresh request to the device's object: the public headers as they came, plus the relay's
  // own routing facts. Any x-relay-* header a client sent is dropped first, so none can be forged.
  const headers = new Headers();
  request.headers.forEach((value, name) => {
    if (!name.toLowerCase().startsWith("x-relay-")) headers.append(name, value);
  });
  headers.set("x-relay-device", route.deviceId);
  headers.set("x-relay-path", route.path);
  headers.set("x-relay-query", query);
  headers.set("x-relay-public-base", base);
  headers.set("x-relay-host", host);
  headers.set("x-relay-proto", url.protocol.replace(":", ""));
  headers.set("x-relay-client-ip", ip);

  const hasBody = request.method !== "GET" && request.method !== "HEAD";
  try {
    return await stubFor(env, route.deviceId).fetch("https://device.internal/forward", {
      method: request.method,
      headers,
      body: hasBody ? request.body : null,
      // The device's redirects (OAuth's return to the client) go back to the client as they are; the relay never follows one.
      redirect: "manual",
    });
  } catch {
    log("forward_failed", { device: route.deviceId, reason: "object_error" });
    return jsonError(502, "relay_error", "The relay couldn't reach this device's connection.");
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const ip = clientIP(request);
    const hostSuffix = suffix(env);

    // Per-device origins: everything on <id>.<suffix> belongs to that device, as it is.
    const hostDevice = deviceFromHost(url.host, hostSuffix);
    if (hostDevice !== null) {
      return forward(request, env, url, ip, { deviceId: hostDevice, path: url.pathname }, url.host, publicBase(env, url, hostDevice));
    }

    const own = await relayRoutes(request, env, url, ip);
    if (own) return own;

    // The path form, only when devices don't have their own origins (so no device shares one).
    if (hostSuffix) return notFound();
    const route = routePublicPath(url.pathname);
    if (!route) return notFound();
    return forward(request, env, url, ip, route, new URL(pathOrigin(env, url)).host, publicBase(env, url, route.deviceId));
  },
} satisfies ExportedHandler<Env>;
