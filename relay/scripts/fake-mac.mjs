#!/usr/bin/env node
// A stand-in for the Mac's relay client, for trying the relay by hand with `wrangler dev`.
// Node 22 or later (global fetch, WebSocket, and WebCrypto); no dependencies.
//
//   node scripts/fake-mac.mjs [--relay http://127.0.0.1:8787] [--key-file .fake-mac.json] [--target http://127.0.0.1:47615] [--unregister]
//
// First run: makes a P-256 key, registers, and saves the key and device id in the key file.
// Later runs: proves the same key and reconnects. Without --target it answers every request
// itself (JSON echo of what it received; /stream answers with three server-sent events).
// With --target it passes each request to that local server, the way the Mac app will.

import { readFileSync, writeFileSync, existsSync } from "node:fs";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : fallback;
};
const relay = opt("relay", "http://127.0.0.1:8787").replace(/\/+$/, "").replace(/^ws/, "http");
const keyFile = opt("key-file", ".fake-mac.json");
const target = opt("target", null);
const unregister = args.includes("--unregister");

const WINDOW = 1024 * 1024; // flow-control window, both ways
const CHUNK = 256 * 1024; // largest chunk
const b64url = (bytes) => Buffer.from(bytes).toString("base64url");
const b64 = (bytes) => Buffer.from(bytes).toString("base64");
const authMessage = (mode, id, nonce) => `tsukumo-relay-v1\nauth\n${mode}\n${id}\n${nonce}`;

async function loadKey() {
  if (existsSync(keyFile)) {
    const saved = JSON.parse(readFileSync(keyFile, "utf8"));
    const privateKey = await crypto.subtle.importKey("jwk", saved.jwk, { name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
    return { privateKey, publicKey: saved.publicKey, deviceId: saved.deviceId, jwk: saved.jwk };
  }
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return { privateKey: pair.privateKey, publicKey: b64url(raw), deviceId: null, jwk: await crypto.subtle.exportKey("jwk", pair.privateKey) };
}

async function sign(privateKey, message) {
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, new TextEncoder().encode(message));
  return b64url(new Uint8Array(sig));
}

const key = await loadKey();

// 1. A challenge: a nonce from the relay (a new device id too, when registering).
const challengeRes = await fetch(`${relay}/challenge${key.deviceId ? `?device=${key.deviceId}` : ""}`);
if (!challengeRes.ok) {
  console.log(`challenge refused: ${challengeRes.status} ${await challengeRes.text()}`);
  process.exit(1);
}
const challenge = await challengeRes.json();
const deviceId = challenge.device_id;

// 2. The socket, with the signature on the upgrade request.
const headers = { "x-tsukumo-nonce": challenge.nonce, "x-tsukumo-signature": await sign(key.privateKey, authMessage(challenge.mode, deviceId, challenge.nonce)) };
if (challenge.mode === "register") headers["x-tsukumo-public-key"] = key.publicKey;
const ws = new WebSocket(`${relay.replace(/^http/, "ws")}/connect?device=${deviceId}`, { headers });

const requests = new Map(); // id -> { controller, body chunks, unacked, wake }
const send = (frame) => ws.send(JSON.stringify(frame));

ws.addEventListener("close", (e) => {
  console.log(`socket closed: ${e.code} ${e.reason}`);
  process.exit(e.code === 1000 || e.code === 4001 ? 0 : 1);
});
ws.addEventListener("error", () => console.log("socket error (a refused signature answers 401 before any socket)"));

ws.addEventListener("message", (event) => {
  const frame = JSON.parse(event.data);
  const r = requests.get(frame.id);
  switch (frame.type) {
    case "ready":
      if (frame.registered) {
        writeFileSync(keyFile, JSON.stringify({ jwk: key.jwk, publicKey: key.publicKey, deviceId: frame.device_id }, null, 2), { mode: 0o600 });
        console.log(`registered; key saved in ${keyFile}`);
      }
      console.log(`ready. public base: ${frame.public_base}`);
      console.log(`try: curl -i ${frame.public_base}/mcp -d '{"hello":"world"}'`);
      if (unregister) send({ type: "unregister" });
      setInterval(() => send({ type: "ping" }), 30_000).unref();
      break;
    case "unregistered":
      console.log("registration deleted");
      break;
    case "req": {
      const state = { controller: new AbortController(), parts: [], unacked: 0, wake: null, done: null };
      state.bodyDone = new Promise((resolve) => (state.done = resolve));
      requests.set(frame.id, state);
      if (!frame.body_stream) {
        state.parts.push(Buffer.from(frame.body_b64, "base64"));
        state.done();
      }
      handle(frame, state).catch((e) => {
        console.log(`request failed: ${e.message}`);
        send({ type: "res", id: frame.id, status: 502, headers: [["content-type", "text/plain"]], body_b64: b64(Buffer.from("fake mac failed")) });
      });
      break;
    }
    case "chunk": // request body
      if (!r) break;
      r.parts.push(Buffer.from(frame.data_b64, "base64"));
      send({ type: "ack", id: frame.id, bytes: Buffer.from(frame.data_b64, "base64").length });
      break;
    case "end":
      r?.done();
      break;
    case "ack": // response bytes the client took
      if (!r) break;
      r.unacked -= frame.bytes;
      r.wake?.();
      break;
    case "cancel":
      console.log(`cancel ${frame.id}`);
      r?.controller.abort();
      requests.delete(frame.id);
      break;
  }
});

/** Sends a streamed answer's body under the window. */
async function sendBody(id, state, bytes) {
  for (let offset = 0; offset < bytes.length; offset += CHUNK) {
    const piece = bytes.subarray(offset, offset + CHUNK);
    while (state.unacked + piece.length > WINDOW && !state.controller.signal.aborted) {
      await new Promise((resolve) => (state.wake = resolve));
    }
    if (state.controller.signal.aborted) return;
    state.unacked += piece.length;
    send({ type: "chunk", id, data_b64: b64(piece) });
  }
}

async function handle(req, state) {
  console.log(`${req.method} ${req.path}${req.query ? "?" + req.query : ""}`);
  await state.bodyDone;
  const body = Buffer.concat(state.parts);
  const finish = () => requests.delete(req.id);

  if (target) {
    const res = await fetch(`${target}${req.path}${req.query ? "?" + req.query : ""}`, {
      method: req.method,
      headers: req.headers.filter(([n]) => n !== "host"),
      body: ["GET", "HEAD"].includes(req.method) ? undefined : body,
      redirect: "manual",
      signal: state.controller.signal,
    });
    send({ type: "res", id: req.id, status: res.status, headers: [...res.headers.entries()], stream: true });
    if (res.body) for await (const chunk of res.body) await sendBody(req.id, state, Buffer.from(chunk));
    if (!state.controller.signal.aborted) send({ type: "end", id: req.id });
    return finish();
  }

  if (req.path === "/stream") {
    send({ type: "res", id: req.id, status: 200, headers: [["content-type", "text/event-stream"]], stream: true });
    for (let i = 1; i <= 3 && !state.controller.signal.aborted; i++) {
      await sendBody(req.id, state, Buffer.from(`data: event ${i}\n\n`));
      await new Promise((r) => setTimeout(r, 500));
    }
    if (!state.controller.signal.aborted) send({ type: "end", id: req.id });
    return finish();
  }

  const echo = {
    method: req.method,
    path: req.path,
    query: req.query,
    headers: Object.fromEntries(req.headers.filter(([n]) => n !== "authorization")),
    body_bytes: body.length,
    body_streamed: Boolean(req.body_stream),
  };
  send({ type: "res", id: req.id, status: 200, headers: [["content-type", "application/json"]], body_b64: b64(Buffer.from(JSON.stringify(echo, null, 2))) });
  finish();
}
