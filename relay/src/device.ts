// One Durable Object per device (SQLite-backed). What lasts is the device's record: its public
// key, when it registered, when its lease was last renewed, and the newest nonce it used. It keeps
// the Mac's one WebSocket (hibernation API) and forwards each public request over it as frames,
// streaming bodies both ways under a flow-control window and the isolate's memory budget.

import { DurableObject } from "cloudflare:workers";
import type { Env } from "./index";
import { budget, encodeCost } from "./budget";
import { log } from "./log";
import {
  LIMITS,
  PROTOCOL,
  authMessage,
  checkNonce,
  decodedLength,
  forwardedRequestHeaders,
  fromBase64,
  fromBase64Url,
  jsonError,
  newNonce,
  notFound,
  publicResponseHeaders,
  toBase64,
  toBase64Url,
  verifyDeviceSignature,
  type Mode,
  type ReadyFrame,
  type RequestFrame,
} from "./protocol";

interface DeviceRecord {
  deviceId: string;
  /** Base64url of the 65-byte uncompressed P-256 point. */
  publicKey: string;
  createdAt: number;
  /** The last authenticated connect (or the lease renewed while connected). */
  renewedAt: number;
  /** Issue time of the newest nonce accepted; a connect must bring a newer one. */
  lastNonce: number;
  /** The registry's reservation, until the registry has confirmed this device (then null). */
  reservation: string | null;
  /** Random per registration. The registry records it, and a release names it, so cleanup of an old registration never touches a newer one. */
  generation: string;
}

/** Left behind by a deleted registration until the registry has released it. */
interface ReleaseMarker {
  deviceId: string;
  generation: string;
}

/** How soon a failed confirmation or release with the registry is tried again. */
const REGISTRY_RETRY_MS = 60_000;

/** Kept on each socket so it survives hibernation. Only proven sockets are ever accepted. */
interface SocketState {
  deviceId: string;
  publicBase: string;
}

interface Pending {
  id: string;
  ws: WebSocket;
  method: string;
  startedAt: number;
  resolve: (response: Response) => void;
  timer?: ReturnType<typeof setTimeout>;
  /** The streamed answer's writer, once `res` with `stream: true` arrived. */
  writer?: WritableStreamDefaultWriter<Uint8Array>;
  /** Answer bytes received so far. */
  bytes: number;
  /** Answer bytes handed to the client's stream and not yet taken by it (acknowledged to the Mac once taken). */
  respUnacked: number;
  /** Request body bytes sent to the Mac and not yet acknowledged. */
  reqUnacked: number;
  /** Bytes charged to the memory budget for this request, released when it ends. */
  charged: number;
  /** Wakes the upload when the Mac acknowledges, or when the request ends. */
  wake?: () => void;
  /** Cancels the upload's reader at once when the request ends. */
  stopUpload?: () => void;
  /** The Mac has finished the answer and the relay is handing the rest to the client. Still tracked (and charged) until it has. */
  draining?: boolean;
}

export const CLOSE = {
  replaced: 4000,
  unregistered: 4001,
  protocol: 4400,
  tooLarge: 4409,
} as const;

function num(value: string | undefined, fallback: number): number {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

class UploadError extends Error {
  constructor(readonly kind: "timeout" | "too_large" | "busy" | "gone") {
    super(kind);
  }
}

export class DeviceRelay extends DurableObject<Env> {
  private device: DeviceRecord | null | undefined;
  private nonceKey: Promise<CryptoKey> | undefined;
  private pending = new Map<string, Pending>();
  /** Uploads still running. One whose request already ended still holds its slot until its task has let go of its buffers. */
  private uploads = new Set<Pending>();
  private tokens: number;
  private refilledAt = Date.now();

  private readonly requestTimeoutMs: number;
  private readonly idleTimeoutMs: number;
  private readonly uploadIdleMs: number;
  private readonly uploadTotalMs: number;
  private readonly perMinute: number;
  private readonly maxInFlight: number;
  private readonly leaseMs: number;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.requestTimeoutMs = num(env.REQUEST_TIMEOUT_MS, 60_000);
    this.idleTimeoutMs = num(env.STREAM_IDLE_TIMEOUT_MS, 60_000);
    this.uploadIdleMs = num(env.UPLOAD_IDLE_TIMEOUT_MS, 15_000);
    this.uploadTotalMs = num(env.UPLOAD_TOTAL_TIMEOUT_MS, 60_000);
    this.perMinute = num(env.DEVICE_REQUESTS_PER_MINUTE, 600);
    this.maxInFlight = num(env.DEVICE_MAX_IN_FLIGHT, 8);
    this.leaseMs = num(env.LEASE_DAYS, 30) * 24 * 60 * 60 * 1000;
    this.tokens = this.perMinute;
    // Keepalives are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}'));
  }

  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === "/challenge") return this.challenge(request);
    if (path === "/connect") return this.openDeviceSocket(request);
    if (path === "/forward") return this.forward(request);
    return notFound();
  }

  // MARK: The device's record and socket

  private async loadDevice(): Promise<DeviceRecord | null> {
    if (this.device === undefined) this.device = (await this.ctx.storage.get<DeviceRecord>("device")) ?? null;
    return this.device;
  }

  /** The key challenges are signed with. It lives only in memory: after an eviction, older nonces simply stop working. */
  private key(): Promise<CryptoKey> {
    this.nonceKey ??= crypto.subtle.generateKey({ name: "HMAC", hash: "SHA-256" }, false, ["sign"]) as Promise<CryptoKey>;
    return this.nonceKey;
  }

  private state(ws: WebSocket): SocketState | null {
    try {
      return (ws.deserializeAttachment() as SocketState | null) ?? null;
    } catch {
      return null;
    }
  }

  private liveSocket(): WebSocket | null {
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState === WebSocket.OPEN && this.state(ws)) return ws;
    }
    return null;
  }

  /** A nonce for the device to sign. Stateless, so a flood of challenges holds nothing open. */
  private async challenge(request: Request): Promise<Response> {
    const mode: Mode = request.headers.get("x-relay-mode") === "register" ? "register" : "connect";
    const deviceId = request.headers.get("x-relay-device") ?? "";
    const device = await this.loadDevice();
    if (mode === "connect" && !device) return notFound();
    if (mode === "register" && device) return jsonError(409, "conflict", "Ask for another challenge.");
    const nonce = await newNonce(await this.key(), mode, deviceId);
    return new Response(JSON.stringify({ protocol: PROTOCOL, mode, device_id: deviceId, nonce, expires_in_ms: LIMITS.nonceLifetimeMs }), {
      headers: { "content-type": "application/json", "cache-control": "no-store" },
    });
  }

  /** The upgrade carries the signed nonce, so a socket is accepted only once the key is proven. */
  private async openDeviceSocket(request: Request): Promise<Response> {
    const deviceId = request.headers.get("x-relay-device") ?? "";
    const publicBase = request.headers.get("x-relay-public-base") ?? "";
    const nonce = request.headers.get("x-tsukumo-nonce") ?? "";
    const signature = request.headers.get("x-tsukumo-signature") ?? "";
    const offeredKey = request.headers.get("x-tsukumo-public-key");
    const mode: Mode = offeredKey ? "register" : "connect";
    const refuse = () => {
      log("auth_failed", { device: deviceId, reason: mode });
      return jsonError(401, "auth_failed", "The signature or nonce didn't check out. Ask for a new challenge.");
    };

    const device = await this.loadDevice();
    if (mode === "connect" && !device) return notFound();
    if (mode === "register" && device) return jsonError(409, "conflict", "This device is already registered.");
    const issued = await checkNonce(await this.key(), mode, deviceId, nonce);
    if (issued === null) return refuse();
    const publicKey = mode === "register" ? offeredKey! : device!.publicKey;
    if (!(await verifyDeviceSignature(publicKey, authMessage(mode, deviceId, nonce), signature))) return refuse();

    const now = Date.now();
    let record: DeviceRecord;
    if (mode === "register") {
      const admission = await this.registry().admit(
        request.headers.get("x-relay-client-ip") ?? "unknown",
        num(this.env.MAX_DEVICES, 10_000),
        num(this.env.REGISTRATIONS_PER_IP_PER_DAY, 3),
      );
      if (admission.verdict === "full") return jsonError(503, "registrations_closed", "The relay isn't taking new devices right now.");
      if (admission.verdict === "ip_daily") return jsonError(429, "rate_limited", "Too many new devices from this address today.", { "retry-after": "86400" });
      if (await this.loadDevice()) {
        await this.registry().cancel(admission.reservation);
        return jsonError(409, "conflict", "This device is already registered.");
      }
      // Saved first, confirmed after: if anything fails in between, the reservation expires on its own
      // (nothing is used up), or this device retries the confirmation from its alarm.
      record = {
        deviceId,
        publicKey: toBase64Url(fromBase64Url(publicKey)!),
        createdAt: now,
        renewedAt: now,
        lastNonce: issued,
        reservation: admission.reservation,
        generation: toBase64Url(crypto.getRandomValues(new Uint8Array(16))),
      };
      log("device_registered", { device: deviceId });
    } else {
      // Single use: checked and moved on with nothing in between, so two racing connects can't share a nonce.
      const current = this.device;
      if (!current) return notFound();
      if (issued <= current.lastNonce) return refuse();
      record = { ...current, renewedAt: now, lastNonce: issued };
    }
    // Saved only if nothing changed underneath: no deletion still releasing (a registration waits for
    // it), and for a connect, the record it checked is still the one stored.
    const kv = this.ctx.storage.kv;
    const saved = this.ctx.storage.transactionSync(() => {
      if (kv.get("releasing") !== undefined) return false;
      const stored = kv.get<DeviceRecord>("device");
      if (mode === "register" ? stored !== undefined : stored?.generation !== record.generation) return false;
      kv.put("device", record);
      return true;
    });
    if (!saved) {
      if (record.reservation) await this.registry().cancel(record.reservation).catch(() => {});
      return jsonError(409, "conflict", "This device is being changed. Try again shortly.");
    }
    this.device = record;
    // The lease: a registration that doesn't connect again within it is deleted (see alarm()).
    await this.ctx.storage.setAlarm(now + this.leaseMs);
    // A live socket always means a counted generation: no socket until the registry has confirmed it.
    if (record.reservation) {
      const confirmed = await this.confirmRegistration();
      if (confirmed === "full") return jsonError(503, "registrations_closed", "The relay isn't taking new devices right now.");
      if (confirmed === "stale") return jsonError(409, "conflict", "This device is being changed. Try again shortly.");
      if (confirmed === "retry") {
        if (mode === "register") {
          // The Mac never learns this id, so the record goes; its confirming marker stays, and the
          // alarm releases the generation in case the confirmation did count.
          const kv = this.ctx.storage.kv;
          this.ctx.storage.transactionSync(() => {
            if (kv.get<DeviceRecord>("device")?.generation === record.generation) kv.delete("device");
          });
          this.device = kv.get<DeviceRecord>("device") ?? null;
          await this.ctx.storage.setAlarm(Date.now() + 1000);
        }
        return jsonError(503, "relay_busy", "The relay couldn't finish this registration. Try again shortly.", { "retry-after": "5" });
      }
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ deviceId, publicBase } satisfies SocketState);
    // One active socket per device: the newly proven one replaces whatever was there.
    for (const other of this.ctx.getWebSockets()) {
      if (other !== server) {
        this.failPending(other, 502, "device_replaced");
        this.closeSocket(other, CLOSE.replaced, "replaced by a newer connection");
        log("device_replaced", { device: deviceId });
      }
    }
    const ready: ReadyFrame = { type: "ready", device_id: deviceId, public_base: publicBase, registered: mode === "register" };
    server.send(JSON.stringify(ready));
    log("device_connected", { device: deviceId });
    return new Response(null, { status: 101, webSocket: client });
  }

  private registry() {
    return this.env.REGISTRY.get(this.env.REGISTRY.idFromName("global"));
  }

  /**
   * Turns the registry's reservation into a counted device. "retry": the registry couldn't be
   * reached (the alarm tries again). "full": the reservation had expired and the relay is now full,
   * so this registration, which was never counted, is deleted.
   */
  private confirming = new Map<string, Promise<"ok" | "full" | "retry" | "stale">>();

  /** One confirmation per generation at a time: a second caller (the alarm and a connect) waits for the first. */
  private confirmRegistration(): Promise<"ok" | "full" | "retry" | "stale"> {
    const device = this.device;
    if (!device?.reservation) return Promise.resolve("ok");
    const running = this.confirming.get(device.generation);
    if (running) return running;
    const attempt = this.confirmOnce(device).finally(() => this.confirming.delete(device.generation));
    this.confirming.set(device.generation, attempt);
    return attempt;
  }

  private async confirmOnce(device: DeviceRecord): Promise<"ok" | "full" | "retry" | "stale"> {
    if (!device.reservation) return "ok";
    // Outstanding until its answer is applied: if the answer is lost, this marker survives (deletion
    // leaves it alone), the alarm releases the generation, and the registry's reconciliation sees it.
    this.ctx.storage.kv.put(`confirming:${device.generation}`, { deviceId: device.deviceId, generation: device.generation } satisfies ReleaseMarker);
    let result: "ok" | "full" | "conflict";
    try {
      result = await this.registry().confirm(device.reservation, device.deviceId, num(this.env.MAX_DEVICES, 10_000), device.generation);
    } catch {
      await this.ctx.storage.setAlarm(Date.now() + REGISTRY_RETRY_MS);
      return "retry";
    }
    if (result === "conflict") {
      // An older registration of this id is still counted (its release is on the way): try again later.
      await this.ctx.storage.setAlarm(Date.now() + REGISTRY_RETRY_MS);
      return "retry";
    }
    return this.finishConfirmation(device.deviceId, device.generation, result);
  }

  /**
   * Applies the registry's answer for one generation, after the await: only if the stored record is
   * still that generation, still waiting on its reservation, and no deletion is releasing. Otherwise
   * nothing is written; a confirmation the registry counted for a registration that's gone is
   * released again (retried from the alarm until it succeeds), so the count stays right.
   */
  async finishConfirmation(deviceId: string, generation: string, result: "ok" | "full"): Promise<"ok" | "full" | "stale"> {
    const kv = this.ctx.storage.kv;
    const marker = `confirming:${generation}`;
    const applyAnswer = (stored: DeviceRecord | undefined, deleting: boolean) => {
      // The same generation, already confirmed (another confirmation got here first): nothing to do,
      // and certainly not an orphan.
      if (stored && stored.generation === generation && !stored.reservation && !deleting) return "already" as const;
      if (!stored || stored.generation !== generation || deleting) return null;
      if (result === "full") {
        kv.delete("device");
        return "deleted" as const;
      }
      kv.put("device", { ...stored, reservation: null });
      return "confirmed" as const;
    };
    const applied = this.ctx.storage.transactionSync(() => {
      const stored = kv.get<DeviceRecord>("device");
      const deleting = kv.get("releasing") !== undefined;
      const outcome = applyAnswer(stored, deleting);
      if (outcome !== null) kv.delete(marker);
      return outcome;
    });
    this.device = (kv.get<DeviceRecord>("device") ?? null);
    if (applied === "deleted") {
      log("registration_refused", { device: deviceId, reason: "full" });
      return "full";
    }
    if (applied === "confirmed" || applied === "already") return "ok";
    // Only now is it an orphan: this generation's record is gone (deleted, or replaced by a newer one).
    // The orphan key is written before the confirming marker goes, so one of them always remains.
    if (result === "ok") await this.releaseOrphan({ deviceId, generation });
    kv.delete(marker);
    return "stale";
  }

  /**
   * For the registry's reconciliation: whether this object still holds `generation`, as its live
   * record or an outstanding confirmation. A definite false lets the registry drop that count.
   */
  async holds(generation: string): Promise<boolean> {
    const kv = this.ctx.storage.kv;
    if (kv.get<DeviceRecord>("device")?.generation === generation) return true;
    return kv.get(`confirming:${generation}`) !== undefined;
  }

  /** Releases a generation the registry counted after its registration was already gone. */
  private async releaseOrphan(orphan: ReleaseMarker): Promise<void> {
    const key = `orphan:${orphan.generation}`;
    this.ctx.storage.kv.put(key, orphan);
    try {
      await this.registry().release(orphan.deviceId, orphan.generation);
      this.ctx.storage.kv.delete(key);
    } catch {
      await this.ctx.storage.setAlarm(Date.now() + REGISTRY_RETRY_MS);
    }
  }

  /**
   * Retries what the registry missed (a confirmation, or a release after deletion), then the lease:
   * renewed while the device is connected, otherwise the registration is deleted.
   */
  async alarm(): Promise<void> {
    const kv = this.ctx.storage.kv;
    // Confirmations whose answer never came: if their registration is gone, the generation may have
    // been counted after the deletion's release, so it's released as an orphan.
    for (const [key, outstanding] of [...kv.list<ReleaseMarker>({ prefix: "confirming:" })]) {
      const stored = kv.get<DeviceRecord>("device");
      if (stored && stored.generation === outstanding.generation) {
        if (!stored.reservation) kv.delete(key);
        continue; // still waiting: the confirmation is retried below
      }
      kv.put(`orphan:${outstanding.generation}`, outstanding);
      kv.delete(key);
    }
    for (const [, orphan] of [...kv.list<ReleaseMarker>({ prefix: "orphan:" })]) await this.releaseOrphan(orphan);
    const releasing = await this.ctx.storage.get<ReleaseMarker>("releasing");
    if (releasing !== undefined) return this.releaseRegistration(releasing);
    const device = await this.loadDevice();
    if (!device) return;
    const now = Date.now();
    if (device.reservation) {
      const result = await this.confirmRegistration();
      if (result === "stale") return;
      if (result === "full") {
        for (const ws of this.ctx.getWebSockets()) this.closeSocket(ws, CLOSE.unregistered, "registration not confirmed: the relay is full");
        return;
      }
      if (result === "retry") return;
      await this.ctx.storage.setAlarm(Math.max(now + 1000, this.device!.renewedAt + this.leaseMs));
      return;
    }
    if (this.liveSocket()) {
      this.device = { ...device, renewedAt: now };
      await this.ctx.storage.put("device", this.device);
      await this.ctx.storage.setAlarm(now + this.leaseMs);
      return;
    }
    if (now - device.renewedAt < this.leaseMs) {
      await this.ctx.storage.setAlarm(device.renewedAt + this.leaseMs);
      return;
    }
    await this.erase();
    log("lease_expired");
  }

  /**
   * Deletes the record and writes the release marker in one transaction, so there's never a moment
   * with neither (a deleted device the registry still counts and nothing left to retry the release).
   * `between` runs between the two writes; tests use it to fail part way.
   */
  eraseRecordSync(between?: () => void): ReleaseMarker {
    const kv = this.ctx.storage.kv;
    const marker = this.ctx.storage.transactionSync((): ReleaseMarker => {
      const stored = kv.get<DeviceRecord>("device");
      const marker = { deviceId: stored?.deviceId ?? this.device?.deviceId ?? "", generation: stored?.generation ?? "" };
      kv.put("releasing", marker);
      between?.();
      kv.delete("device");
      return marker;
    });
    this.device = null;
    return marker;
  }

  /** Deletes the registration, then releases its place in the registry (retried from the alarm until it succeeds). */
  private async erase(): Promise<void> {
    const marker = this.eraseRecordSync();
    await this.ctx.storage.setAlarm(Date.now() + REGISTRY_RETRY_MS);
    await this.releaseRegistration(marker);
  }

  /**
   * Releases a deleted registration's place, then removes its marker. It never deletes a record or an
   * alarm: a registration made after this one (only possible once the marker is gone) is left alone,
   * and the registry releases only the generation named.
   */
  private async releaseRegistration(marker: ReleaseMarker): Promise<void> {
    try {
      await this.registry().release(marker.deviceId, marker.generation);
    } catch {
      await this.ctx.storage.setAlarm(Date.now() + REGISTRY_RETRY_MS);
      return;
    }
    const kv = this.ctx.storage.kv;
    this.ctx.storage.transactionSync(() => {
      const current = kv.get<ReleaseMarker>("releasing");
      if (current && current.deviceId === marker.deviceId && current.generation === marker.generation) kv.delete("releasing");
    });
    // A record stored meanwhile keeps its own lease (this alarm firing may have used up its schedule).
    const device = await this.loadDeviceFresh();
    if (device) await this.ctx.storage.setAlarm(device.reservation ? Date.now() + REGISTRY_RETRY_MS : device.renewedAt + this.leaseMs);
  }

  private async loadDeviceFresh(): Promise<DeviceRecord | null> {
    this.device = undefined;
    return this.loadDevice();
  }

  private closeSocket(ws: WebSocket, code: number, reason: string): void {
    try {
      ws.close(code, reason);
    } catch {
      // Already closed.
    }
  }

  private send(ws: WebSocket, frame: unknown): boolean {
    try {
      ws.send(JSON.stringify(frame));
      return true;
    } catch {
      return false;
    }
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return this.closeSocket(ws, CLOSE.protocol, "text frames only");
    // Sized before it's parsed, so no frame can make the relay build a large object.
    if (message.length > LIMITS.maxFrameChars) {
      this.failPending(ws, 502, "bad_device_response");
      return this.closeSocket(ws, CLOSE.tooLarge, "frame too large");
    }
    let frame: Record<string, unknown>;
    try {
      const parsed = JSON.parse(message);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
      frame = parsed;
    } catch {
      return this.closeSocket(ws, CLOSE.protocol, "bad frame");
    }
    const state = this.state(ws);
    if (!state) return this.closeSocket(ws, CLOSE.protocol, "unknown socket");

    switch (frame.type) {
      case "res":
        return this.onResponse(ws, frame);
      case "chunk":
        return this.onChunk(ws, frame);
      case "end":
        return this.onEnd(ws, frame);
      case "ack":
        return this.onAck(ws, frame);
      case "unregister":
        return this.unregister(ws, state);
      default:
        return; // Unknown frames are ignored, so a newer Mac can talk to an older relay.
    }
  }

  private async unregister(ws: WebSocket, state: SocketState): Promise<void> {
    if (await this.loadDevice()) await this.erase();
    this.failPending(null, 503, "device_offline");
    this.send(ws, { type: "unregistered", device_id: state.deviceId });
    for (const other of this.ctx.getWebSockets()) this.closeSocket(other, CLOSE.unregistered, "unregistered");
    log("device_unregistered", { device: state.deviceId });
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    this.failPending(ws, 502, "device_disconnected");
    this.closeSocket(ws, code === 1005 || code === 1006 ? 1000 : code, "closed");
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.failPending(ws, 502, "device_disconnected");
  }

  // MARK: Public requests

  private takeToken(): boolean {
    const now = Date.now();
    this.tokens = Math.min(this.perMinute, this.tokens + ((now - this.refilledAt) * this.perMinute) / 60_000);
    this.refilledAt = now;
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    return true;
  }

  private charge(entry: Pending, bytes: number): boolean {
    if (!budget.reserve(bytes)) return false;
    entry.charged += bytes;
    return true;
  }

  private discharge(entry: Pending, bytes: number): void {
    const n = Math.min(bytes, entry.charged);
    entry.charged -= n;
    budget.release(n);
  }

  private async forward(request: Request): Promise<Response> {
    const deviceId = request.headers.get("x-relay-device") ?? "";
    const device = await this.loadDevice();
    if (!device) return notFound();
    const ws = this.liveSocket();
    if (!ws) return jsonError(503, "device_offline", "This device isn't connected right now.", { "retry-after": "30" });
    if (!this.takeToken()) return jsonError(429, "rate_limited", "Too many requests for this device.", { "retry-after": "5" });
    // Uploads count: an entry exists from the first byte, so slow bodies can't get around the cap.
    if (this.inFlight() >= this.maxInFlight) {
      return jsonError(429, "too_many_in_flight", "Too many requests are waiting on this device.", { "retry-after": "1" });
    }
    const declared = request.headers.has("content-length") ? Number(request.headers.get("content-length")) : null;
    if (declared !== null && (!Number.isFinite(declared) || declared > LIMITS.maxRequestBytes)) {
      return jsonError(413, "too_large", "The request body is too large.");
    }
    const hasBody = request.body !== null && declared !== 0;
    const inline = !hasBody || (declared !== null && declared <= LIMITS.inlineRequestBytes);

    return new Promise<Response>((resolve) => {
      const entry: Pending = {
        id: crypto.randomUUID(),
        ws,
        method: request.method,
        startedAt: Date.now(),
        resolve: (response) => {
          log("forwarded", { device: deviceId, method: request.method, status: response.status, ms: Date.now() - entry.startedAt });
          resolve(response);
        },
        bytes: 0,
        respUnacked: 0,
        reqUnacked: 0,
        charged: 0,
      };
      this.pending.set(entry.id, entry);
      // If the public client goes away first, the Mac is told to stop.
      request.signal?.addEventListener?.("abort", () => this.clientGone(entry));
      const head: Omit<RequestFrame, "body_b64"> = {
        type: "req",
        id: entry.id,
        method: request.method,
        path: request.headers.get("x-relay-path") ?? "/",
        query: request.headers.get("x-relay-query") ?? "",
        headers: forwardedRequestHeaders(request.headers, {
          host: request.headers.get("x-relay-host") ?? "",
          clientIP: request.headers.get("x-relay-client-ip") ?? "unknown",
          proto: request.headers.get("x-relay-proto") ?? "https",
          publicBase: request.headers.get("x-relay-public-base") ?? "",
        }),
      };
      this.upload(entry, request, head, inline ? (declared ?? 0) : null).catch((error: unknown) => {
        const kind = error instanceof UploadError ? error.kind : "gone";
        if (kind === "timeout") this.finish(entry, jsonError(408, "upload_timeout", "The request body arrived too slowly."), true);
        else if (kind === "too_large") this.finish(entry, jsonError(413, "too_large", "The request body is too large."), true);
        else if (kind === "busy") this.finish(entry, jsonError(503, "relay_busy", "The relay is busy. Try again shortly.", { "retry-after": "2" }), true);
        else this.clientGone(entry);
      });
    });
  }

  private live(entry: Pending): boolean {
    return this.pending.get(entry.id) === entry;
  }

  /** Still exchanging frames with the Mac (not finished, not draining). */
  private sending(entry: Pending): boolean {
    return this.live(entry) && !entry.draining;
  }

  /** Requests holding a slot: those still tracked, plus ended ones whose upload task hasn't stopped yet. */
  inFlight(): number {
    let ended = 0;
    for (const entry of this.uploads) if (!this.live(entry)) ended++;
    return this.pending.size + ended;
  }

  /**
   * Sends the request: inline when small and its length is known, otherwise as chunks under the
   * window. A streamed body is read through a BYOB reader (at most one chunk) when the body allows
   * it; otherwise each read is whatever the stream yields. Every buffer the task holds is charged to
   * the task from the moment it arrives until the task lets go of it (ending the request doesn't
   * release it; the task's finally does), and bytes sent to the Mac are the entry's until the Mac
   * acknowledges them, so nothing held is uncounted.
   */
  private async upload(entry: Pending, request: Request, head: Omit<RequestFrame, "body_b64">, inlineLength: number | null): Promise<void> {
    const body = request.body;
    let byob: ReadableStreamBYOBReader | null = null;
    let reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
    if (body && inlineLength === null) {
      try {
        byob = body.getReader({ mode: "byob" });
      } catch {
        reader = body.getReader();
      }
    } else if (body) {
      // Inline bodies are small and of known length; each buffer the stream yields is charged while it's copied.
      reader = body.getReader();
    }
    const deadline = Date.now() + this.uploadTotalMs;
    const read = async (): Promise<ReadableStreamReadResult<Uint8Array>> => {
      const left = Math.min(this.uploadIdleMs, deadline - Date.now());
      if (left <= 0) throw new UploadError("timeout");
      let timer: ReturnType<typeof setTimeout> | undefined;
      const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new UploadError("timeout")), left);
      });
      try {
        const next = byob ? byob.read(new Uint8Array(LIMITS.maxChunkBytes)) : reader!.read();
        return (await Promise.race([next, timeout])) as ReadableStreamReadResult<Uint8Array>;
      } catch (error) {
        if (error instanceof UploadError) throw error;
        throw new UploadError("gone");
      } finally {
        if (timer) clearTimeout(timer);
      }
    };
    const stop = () => (byob ?? reader)?.cancel().catch(() => {});
    const dropped = () => this.finish(entry, jsonError(502, "device_disconnected", "The device's connection dropped."), false);
    // The buffers this task holds are charged to the task, not the entry: ending the request doesn't
    // release them; the task does, in its finally, once it no longer holds them.
    let own = 0;
    const take = (bytes: number) => {
      if (!budget.reserve(bytes)) throw new UploadError("busy");
      own += bytes;
    };
    const give = (bytes: number) => {
      const n = Math.min(bytes, own);
      own -= n;
      budget.release(n);
    };
    /** After every await: if the request ended meanwhile, stop. */
    const ended = () => !this.sending(entry);
    this.uploads.add(entry);
    entry.stopUpload = stop;

    try {
      if (inlineLength !== null) {
        const cost = encodeCost(inlineLength);
        take(cost);
        const buffer = new Uint8Array(inlineLength);
        let filled = 0;
        while (reader) {
          const { done, value } = await read();
          if (ended()) return stop();
          if (done) break;
          // The stream's own buffer is held while it's copied: charged for that long.
          take(value.byteLength);
          const fits = filled + value.byteLength <= inlineLength;
          if (fits) buffer.set(value, filled);
          filled += value.byteLength;
          give(value.byteLength);
          if (!fits) throw new UploadError("too_large");
        }
        if (ended()) return stop();
        const sent = this.send(entry.ws, { ...head, body_b64: toBase64(buffer.subarray(0, filled)) });
        give(cost);
        if (!sent) return dropped();
      } else {
        if (!this.send(entry.ws, { ...head, body_b64: "", body_stream: true })) return dropped();
        let total = 0;
        for (;;) {
          const { done, value } = await read();
          if (ended()) return stop();
          if (done) break;
          total += value.byteLength;
          if (total > LIMITS.maxRequestBytes) throw new UploadError("too_large");
          // The whole read is held until its last piece has been sent: charged for exactly that long.
          take(value.byteLength);
          try {
            for (let offset = 0; offset < value.byteLength; offset += LIMITS.maxChunkBytes) {
              const piece = value.subarray(offset, offset + LIMITS.maxChunkBytes);
              // The window: wait for the Mac's acknowledgements before sending more.
              while (!ended() && entry.reqUnacked + piece.byteLength > LIMITS.flowWindowBytes) {
                if (Date.now() > deadline) throw new UploadError("timeout");
                await new Promise<void>((wake) => {
                  entry.wake = wake;
                  setTimeout(wake, 1000);
                });
              }
              if (ended()) return stop();
              // The piece's base64 and frame copies are charged while they exist; the bytes in flight
              // to the Mac are the entry's until it acknowledges them (or the request ends).
              const framing = encodeCost(piece.byteLength) - piece.byteLength;
              take(framing);
              if (!this.charge(entry, piece.byteLength)) throw new UploadError("busy");
              const sent = this.send(entry.ws, { type: "chunk", id: entry.id, data_b64: toBase64(piece) });
              give(framing);
              if (!sent) return dropped();
              entry.reqUnacked += piece.byteLength;
            }
          } finally {
            give(value.byteLength);
          }
        }
        if (!this.send(entry.ws, { type: "end", id: entry.id })) return dropped();
      }
    } catch (error) {
      stop();
      throw error;
    } finally {
      give(own);
      this.uploads.delete(entry);
      entry.stopUpload = undefined;
    }
    // The wait for an answer starts once the whole request is with the Mac.
    if (this.sending(entry) && !entry.writer) {
      this.arm(entry, this.requestTimeoutMs, () => this.finish(entry, jsonError(504, "device_timeout", "The device didn't answer in time."), true));
    }
  }

  private arm(entry: Pending, ms: number, fire: () => void): void {
    if (entry.timer) clearTimeout(entry.timer);
    entry.timer = setTimeout(fire, ms);
  }

  /** Ends a request: settles it if no answer has started, or ends its stream. Releases everything it held. */
  private finish(entry: Pending, response: Response | null, cancel: boolean, abortStream = true): void {
    if (!this.live(entry)) return;
    this.pending.delete(entry.id);
    if (entry.timer) clearTimeout(entry.timer);
    this.discharge(entry, entry.charged);
    entry.wake?.();
    // A running upload's reader is cancelled now; its task releases its own buffers as it stops.
    entry.stopUpload?.();
    if (cancel) this.send(entry.ws, { type: "cancel", id: entry.id });
    if (entry.writer) {
      // A stream the relay ends errors for the client; one the client left needs nothing more.
      if (abortStream) entry.writer.abort("relay ended the response").catch(() => {});
    } else if (response) {
      entry.resolve(response);
    }
  }

  private clientGone(entry: Pending): void {
    if (!this.live(entry)) return;
    log("client_gone", { device: this.state(entry.ws)?.deviceId, reason: "cancel" });
    // A draining answer is already finished on the Mac, so it needs no cancel.
    this.finish(entry, new Response(null, { status: 499 }), !entry.draining, false);
  }

  /** A draining answer reached the client: forget it and release what it held. */
  private drained(entry: Pending): void {
    if (!this.live(entry)) return;
    // The answer is complete: an upload still reading is stopped now (its task releases its own buffers).
    entry.stopUpload?.();
    this.pending.delete(entry.id);
    if (entry.timer) clearTimeout(entry.timer);
    this.discharge(entry, entry.charged);
  }

  /** Hands the rest of an answer to the client, tracked (and charged) until it's taken, with a deadline. */
  private drain(entry: Pending): void {
    entry.draining = true;
    entry.wake?.();
    // The Mac has answered in full: any upload still reading stops now rather than at its deadline.
    entry.stopUpload?.();
    this.arm(entry, this.idleTimeoutMs, () => this.finish(entry, null, false));
    entry.writer!.close().then(
      () => this.drained(entry),
      () => this.finish(entry, null, false, false),
    );
  }

  private failPending(ws: WebSocket | null, status: number, error: string): void {
    for (const entry of [...this.pending.values()]) {
      if (ws === null || entry.ws === ws) {
        this.finish(entry, jsonError(status, error, "The device's connection dropped."), false);
      }
    }
  }

  private entryFor(ws: WebSocket, frame: Record<string, unknown>): Pending | null {
    if (typeof frame.id !== "string") return null;
    const entry = this.pending.get(frame.id);
    return entry && entry.ws === ws && !entry.draining ? entry : null;
  }

  private badResponse(entry: Pending): void {
    this.finish(entry, jsonError(502, "bad_device_response", "The device sent an answer the relay couldn't read."), true);
  }

  /** Decodes a body field after checking its size, so nothing over the limit is ever decoded. */
  private decode(entry: Pending, value: unknown): Uint8Array | null {
    if (typeof value !== "string" || decodedLength(value) > LIMITS.maxChunkBytes) return null;
    return fromBase64(value);
  }

  private onResponse(ws: WebSocket, frame: Record<string, unknown>): void {
    const entry = this.entryFor(ws, frame);
    if (!entry || entry.writer) return;
    const status = frame.status;
    if (typeof status !== "number" || !Number.isInteger(status) || status < 200 || status > 599) return this.badResponse(entry);
    const headers = publicResponseHeaders(frame.headers);
    if (!headers) return this.badResponse(entry);
    const noBody = entry.method === "HEAD" || status === 204 || status === 205 || status === 304;
    let first: Uint8Array = new Uint8Array();
    if (frame.body_b64 !== undefined && frame.body_b64 !== "") {
      const decoded = this.decode(entry, frame.body_b64);
      if (!decoded) return this.badResponse(entry);
      first = decoded;
    }
    // A body the Mac already encoded is passed on as it is, never compressed a second time.
    const init: ResponseInit = { status, headers, encodeBody: headers.has("content-encoding") ? "manual" : "automatic" };

    if (frame.stream === true && !noBody) {
      const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
      const writer = writable.getWriter();
      entry.writer = writer;
      // A cancelled response body (the public client hung up) errors the writable side.
      writer.closed.catch(() => this.clientGone(entry));
      this.arm(entry, this.idleTimeoutMs, () => this.finish(entry, null, true));
      entry.resolve(new Response(readable, init));
      if (first.byteLength > 0) this.write(entry, first);
      return;
    }
    // The answer is complete. The request may still be uploading; the Mac doesn't want the rest.
    if (noBody || first.byteLength === 0) {
      entry.wake?.();
      this.drained(entry);
      entry.resolve(new Response(noBody ? null : first, init));
      return;
    }
    // Its body stays charged until the client has taken it (a fixed-length stream keeps Content-Length).
    if (!this.charge(entry, first.byteLength)) {
      return this.finish(entry, jsonError(503, "relay_busy", "The relay is busy. Try again shortly.", { "retry-after": "2" }), true);
    }
    const { readable, writable } = new FixedLengthStream(first.byteLength);
    entry.writer = writable.getWriter() as WritableStreamDefaultWriter<Uint8Array>;
    entry.resolve(new Response(readable, init));
    entry.writer.write(first).catch(() => {});
    this.drain(entry);
  }

  private write(entry: Pending, data: Uint8Array): void {
    entry.bytes += data.byteLength;
    // The Mac may have at most one window unacknowledged; past it (or past the budget) the stream ends.
    if (entry.bytes > LIMITS.maxResponseBytes || entry.respUnacked + data.byteLength > LIMITS.flowWindowBytes + LIMITS.maxChunkBytes) {
      return this.finish(entry, null, true);
    }
    if (!this.charge(entry, data.byteLength)) return this.finish(entry, null, true);
    entry.respUnacked += data.byteLength;
    entry.writer!.write(data).then(
      () => {
        if (!this.live(entry)) return;
        entry.respUnacked -= data.byteLength;
        this.discharge(entry, data.byteLength);
        if (!entry.draining) this.send(entry.ws, { type: "ack", id: entry.id, bytes: data.byteLength });
      },
      () => this.clientGone(entry),
    );
  }

  private onChunk(ws: WebSocket, frame: Record<string, unknown>): void {
    const entry = this.entryFor(ws, frame);
    if (!entry || !entry.writer) return;
    const data = this.decode(entry, frame.data_b64);
    if (!data) return this.finish(entry, null, true);
    this.arm(entry, this.idleTimeoutMs, () => this.finish(entry, null, true));
    if (data.byteLength > 0) this.write(entry, data);
  }

  private onEnd(ws: WebSocket, frame: Record<string, unknown>): void {
    const entry = this.entryFor(ws, frame);
    if (!entry || !entry.writer) return;
    // Whatever is still queued for the client stays tracked and charged until it has drained.
    this.drain(entry);
  }

  private onAck(ws: WebSocket, frame: Record<string, unknown>): void {
    const entry = this.entryFor(ws, frame);
    if (!entry || typeof frame.bytes !== "number" || !Number.isFinite(frame.bytes) || frame.bytes <= 0) return;
    const bytes = Math.min(frame.bytes, entry.reqUnacked);
    entry.reqUnacked -= bytes;
    this.discharge(entry, bytes);
    entry.wake?.();
  }
}
