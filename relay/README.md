# The Tsukumo relay

A public address for the KemoSabe gateway on the owner's Mac, so cloud agents (Claude's custom connectors, ChatGPT's developer-mode connectors, Grok, OpenClaw) can reach it. The Mac keeps one outbound WebSocket to the relay; each device gets a stable address (`https://<id>.<domain>`, or `https://<host>/d/<id>` on workers.dev); the relay forwards each HTTP request over that socket and returns the Mac's answer, byte for byte. It stores each device's public key and lease, a count of devices, and for one day salted hashes of the addresses that registered. Sign-in, consent, grants, budgets, and policy all stay on the Mac.

It's a Cloudflare Worker with one SQLite-backed Durable Object per device (`src/device.ts`), which holds the device's socket through the WebSocket hibernation API, and one `Registry` object (`src/registry.ts`). How it fits, its trust boundary, device authentication, and **the envelope the Mac client implements** are in [docs/ARCHITECTURE.md, The Tsukumo relay](../docs/ARCHITECTURE.md#the-tsukumo-relay).

**Status:** built; not deployed (that's the owner's step, below), and the Mac's client is the KemoSabe gateway's public address (Settings, Gateway, Public address; `RelayConnection` in TsukumoKit).

## Files

| File | What it holds |
|---|---|
| `src/index.ts` | The Worker: `/challenge`, `/connect`, per-device origins and the path form (with the path-inserted `.well-known` forms), per-IP rate limits, path and header checks |
| `src/device.ts` | `DeviceRelay`, the Durable Object: registration, the signed upgrade, the 30-day lease, one live socket, forwarding, bodies streamed both ways under the flow-control window, cancel, timeouts, per-device limits |
| `src/registry.ts` | `Registry`: the device cap (reservations a device confirms after saving itself, expiring unconfirmed) and the daily per-address cap |
| `src/budget.ts` | The memory budget every held byte is charged to |
| `src/protocol.ts` | Frames, nonces, the signed message, header filtering both ways and the security headers, path rules, limits, encodings, signature checks |
| `src/log.ts` | The only logging: fixed fields, never bodies, headers, paths, or queries |
| `scripts/fake-mac.mjs` | A stand-in Mac client for trying the relay by hand |
| `wrangler.jsonc` | The Worker, the Durable Objects and their migration, rate limits, settings, observability |

## Develop

Node 22 or later. Nothing here needs a Cloudflare account or the network once packages are installed.

```bash
cd relay
npm ci                 # pinned versions from package-lock.json
npm run typecheck
```

There's no test suite (October 8, 2026); try it by hand with `npm run dev` and the fake Mac, below.

**By hand:** `npm run dev` (that's `wrangler dev`, local only, on http://127.0.0.1:8787), then in another terminal:

```bash
node scripts/fake-mac.mjs                       # registers, saves its key in .fake-mac.json, prints the public base
curl -i http://127.0.0.1:8787/d/<id>/mcp -d '{"hello":"world"}'    # echoed back by the fake Mac, with the relay's security headers
curl -N http://127.0.0.1:8787/d/<id>/stream                         # three server-sent events
node scripts/fake-mac.mjs --target http://127.0.0.1:47615           # pass requests to a local gateway instead
node scripts/fake-mac.mjs --unregister                              # delete the registration
```

Running it again reconnects with the saved key and replaces the earlier socket. `--relay https://<host>` points it at a deployed relay. With `--target`, the fake Mac drops the `host` header (Node's fetch sets its own), so the gateway's Host check sees `127.0.0.1`; the real client keeps the public host (see the envelope spec).

## Settings

In `wrangler.jsonc`, `vars`:

| Setting | Default | Meaning |
|---|---|---|
| `DEVICE_HOST_SUFFIX` | empty | Per-device origins: the wildcard domain's apex (`tsukumo-relay.example`); each device is then `https://<id>.<suffix>` and the path form is off. Empty: the path form. |
| `PUBLIC_ORIGIN` | empty | The path form's origin when it differs from the request's own. |
| `REQUEST_TIMEOUT_MS` | 60000 | How long the Mac has to start answering once the request is with it (then 504 and a `cancel`) |
| `STREAM_IDLE_TIMEOUT_MS` | 60000 | The longest gap between chunks of a streamed answer |
| `UPLOAD_IDLE_TIMEOUT_MS` | 15000 | The longest gap while a request body arrives (then 408, a `cancel`, and the slot freed) |
| `UPLOAD_TOTAL_TIMEOUT_MS` | 60000 | The longest a request body may take in all |
| `DEVICE_REQUESTS_PER_MINUTE` | 600 | Per device (then 429) |
| `DEVICE_MAX_IN_FLIGHT` | 8 | Requests on one device at once, uploads included (then 429) |
| `LEASE_DAYS` | 30 | A registration that doesn't connect for this long is deleted |
| `MAX_DEVICES` | 10000 | Registrations the relay keeps (then new ones get 503) |
| `REGISTRATIONS_PER_IP_PER_DAY` | 3 | Per client address (then 429) |
| `RECONCILE_MINUTES` | 60 | How often a reconciliation pass starts (from its scheduled start); the count is eventually consistent, right again within about one period plus one pass |
| `RECONCILE_BATCH` | 250 | Device objects checked per reconciliation step |
| `RECONCILE_CONCURRENCY` | 25 | Checks running at once |

Rate limits per client address (Cloudflare's rate limiting binding, `ratelimits`): 300 requests a minute in all (`IP_LIMITER`), 5 registration challenges a minute (`REGISTER_LIMITER`), and 10 challenges a minute per device and address (`CHALLENGE_LIMITER`). Fixed limits are in `src/protocol.ts` (`LIMITS`): 12 MB request bodies, 100 MB answers, 256 KiB inline bodies and chunks, a 1 MiB flow-control window, 400 KiB frames, a 48 MiB memory budget per isolate, 30-second nonces, 2,048-character paths, 100 headers or 32 KB of them.

**Logs:** only the relay's own lines (an event, the first 6 characters of a device id, a status, a method, a duration). Cloudflare's invocation logs and traces are off (`observability.logs.invocation_logs: false`, `traces.enabled: false`) because they would record each request's full URL, with device ids and OAuth parameters; query strings are redacted anywhere a URL still appears, and Logpush is off. Keep it that way. `npx wrangler tail` (live, for the owner only) still shows each request's URL as it happens; nothing is kept.

## Deploy (the owner)

Nothing has been deployed, and no Cloudflare account has been signed in to from this repository. When the owner decides to:

1. **Sign in, once:** `cd relay && npm ci && npx wrangler login` (opens the browser; the owner signs in to Cloudflare). `npx wrangler whoami` shows the account.
2. **Pick the address.**
   - **Recommended: per-device origins on a domain of its own.** Each device gets its own origin, `https://<id>.<domain>`, so no two devices ever share cookies, storage, or service workers, and the gateway's public base is a plain origin it already accepts. This needs a wildcard on a zone on this Cloudflare account. Cloudflare's free certificate covers `*.<zone>` but not a wildcard one level deeper, so use a domain of its own (for example `tsukumo-relay.net`, devices at `<id>.tsukumo-relay.net`) rather than `*.relay.zlichtman.com`, which would need Advanced Certificate Manager. On October 6, 2026, zlichtman.com's nameservers were GoDaddy's (`domaincontrol.com`), so it isn't a Cloudflare zone anyway. Steps: add the domain to Cloudflare; in its DNS add a proxied `AAAA` record for `@` and one for `*`, both `100::`; in `wrangler.jsonc` uncomment `routes` (the apex and `*.<domain>/*`, each with `zone_name`), set `DEVICE_HOST_SUFFIX` to the domain, and set `"workers_dev": false`. The relay's own endpoints are then `https://<domain>/challenge` and `wss://<domain>/connect`.
   - **workers.dev** (no domain, the path form): keep `"workers_dev": true` and `DEVICE_HOST_SUFFIX` empty. The first deploy asks for the account's workers.dev subdomain if it has none. The relay is `https://tsukumo-relay.<subdomain>.workers.dev` and devices are `…/d/<id>`, sharing one origin under the sandbox and header protections (docs/ARCHITECTURE.md). The Mac side then also needs the gateway to accept a public base with a path.
3. **Deploy:** `npm run typecheck && npx wrangler deploy`. The first deploy applies the Durable Object migration (`v1`, `new_sqlite_classes: ["DeviceRelay", "Registry"]`, which the Workers Free plan supports). In the dashboard, check the Worker's Observability settings show invocation logs off.
4. **Check it:** `curl https://<host>/healthz` answers `ok`; `node scripts/fake-mac.mjs --relay https://<host> --key-file /tmp/relay-check.json` registers and prints the public base; `curl -i <public base>/mcp -d '{}'` comes back from the fake Mac; `node scripts/fake-mac.mjs --relay https://<host> --key-file /tmp/relay-check.json --unregister` deletes that test device.

Undo: `npx wrangler rollback` returns to the previous version; `npx wrangler delete` removes the Worker and its Durable Objects (every device registers again afterwards). Check Cloudflare's current Workers Free limits (requests a day, Durable Object duration) against expected traffic; hibernation keeps an idle socket from counting duration. If registrations are ever abused despite the caps, the next step is an enrollment token the Tsukumo app presents to register (not built).
