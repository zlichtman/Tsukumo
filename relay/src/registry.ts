// One global object that admits registrations: a cap on how many devices the relay keeps, and a
// daily cap per client IP. A device object asks it to admit a registration once the signature
// checks out and gets a reservation, saves itself, then confirms the reservation under its device
// id. A reservation that isn't confirmed within a minute expires, so a failure between the two
// objects doesn't keep a place taken. A confirmation that comes after its reservation expired is
// checked against the cap again and refused when the relay is full (the device then deletes
// itself). Ending a registration releases its device id. Confirm and release are idempotent by
// device id and name a registration's generation, and every change that touches more than one key happens in one synchronous storage
// transaction, so a failure part way leaves nothing half written.
//
// The count is eventually consistent: reconciliation (below) asks each counted device object, once
// per period, whether it still holds the generation counted, and drops the counts nobody holds, so
// a leak a crash or a lost message leaves heals within about one period plus one pass (longer while
// a device can't be reached). A re-registration that meets a stale count of its own id ("conflict")
// waits for that. The count is an anti-abuse limit, not a security boundary.
//
// It is a single object on purpose: registrations are rare, and one object handles far more than
// the relay will ever see. If that ever changes, shard it by the device id's first character with
// a share of the cap each (the total then stays under the cap, but one shard can fill early).

import { DurableObject } from "cloudflare:workers";
import type { Env } from "./index";
import { toBase64Url } from "./protocol";

export type Admission = { verdict: "ok"; reservation: string } | { verdict: "full" } | { verdict: "ip_daily" };
export type Confirmation = "ok" | "full" | "conflict";

export const RESERVATION_TTL_MS = 60_000;
/** Device objects asked per reconciliation step, and how many at once (RECONCILE_BATCH, RECONCILE_CONCURRENCY). */
export const RECONCILE_BATCH = 250;
export const RECONCILE_CONCURRENCY = 25;
const HOLDS_TIMEOUT_MS = 10_000;

function today(now = Date.now()): string {
  return new Date(now).toISOString().slice(0, 10);
}

export class Registry extends DurableObject<Env> {
  private get kv(): SyncKvStorage {
    return this.ctx.storage.kv;
  }

  /** Deletes reservations past their time and returns the keys of the live ones. Call inside a transaction. */
  private pruneSync(now: number): string[] {
    const live: string[] = [];
    for (const [key, until] of [...this.kv.list<number>({ prefix: "res:" })]) {
      if (until <= now) this.kv.delete(key);
      else live.push(key);
    }
    return live;
  }

  private countSync(): number {
    return this.kv.get<number>("count") ?? 0;
  }

  /** Today's salt for hashing client addresses; a new day deletes the old entries and salt. */
  private saltSync(now: number): string {
    return this.ctx.storage.transactionSync(() => {
      const day = today(now);
      const salt = this.kv.get<string>("salt");
      if (this.kv.get<string>("day") === day && salt) return salt;
      for (const [key] of [...this.kv.list({ prefix: "ip:" })]) this.kv.delete(key);
      const fresh = toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
      this.kv.put("day", day);
      this.kv.put("salt", fresh);
      return fresh;
    });
  }

  /**
   * Reserves a place for one registration if the relay is under `cap` devices (confirmed ones and
   * live reservations together) and this client address under `perIPDaily` registrations today.
   * The address is kept only as an HMAC with a salt made for the day.
   */
  async admit(clientIP: string, cap: number, perIPDaily: number): Promise<Admission> {
    const now = Date.now();
    const salt = this.saltSync(now);
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(salt), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(clientIP)));
    const ipKey = `ip:${toBase64Url(mac.subarray(0, 16))}`;
    const reservation = toBase64Url(crypto.getRandomValues(new Uint8Array(16)));
    const admission = this.ctx.storage.transactionSync((): Admission => {
      if (this.countSync() + this.pruneSync(now).length >= cap) return { verdict: "full" };
      const used = this.kv.get<number>(ipKey) ?? 0;
      if (used >= perIPDaily) return { verdict: "ip_daily" };
      this.kv.put(`res:${reservation}`, now + RESERVATION_TTL_MS);
      this.kv.put(ipKey, used + 1);
      return { verdict: "ok", reservation };
    });
    await this.schedule(now);
    return admission;
  }

  /**
   * The device saved itself: its reservation becomes a counted device. Idempotent for the same
   * generation; "conflict" when another generation of the id is still counted. A confirmation whose
   * reservation already expired takes a place only if one is free, and is refused otherwise.
   */
  async confirm(reservation: string, deviceId: string, cap: number, generation: string): Promise<Confirmation> {
    const result = this.confirmSync(reservation, deviceId, cap, generation);
    await this.schedule(Date.now());
    return result;
  }

  /** `between` runs after the first write; tests use it to fail part way. */
  confirmSync(reservation: string, deviceId: string, cap: number, generation: string, between?: () => void): Confirmation {
    return this.ctx.storage.transactionSync((): Confirmation => {
      const now = Date.now();
      const resKey = `res:${reservation}`;
      const counted = this.kv.get<string>(`dev:${deviceId}`);
      if (counted === generation) {
        this.kv.delete(resKey);
        return "ok";
      }
      // Another generation of this id is still counted: never overwritten. The device retries once
      // that one is released (its reservation still holds its place meanwhile, or lapses).
      if (counted !== undefined) return "conflict";
      const live = this.pruneSync(now);
      const held = live.includes(resKey);
      if (!held && this.countSync() + live.length >= cap) return "full";
      this.kv.delete(resKey);
      between?.();
      this.kv.put(`dev:${deviceId}`, generation);
      this.kv.put("count", this.countSync() + 1);
      return "ok";
    });
  }

  /** A reservation that won't be used (the device found itself already registered). */
  async cancel(reservation: string): Promise<void> {
    this.kv.delete(`res:${reservation}`);
  }

  /** A registration ended. Idempotent, and only for the generation named: a newer registration under the same id stays counted. */
  async release(deviceId: string, generation: string): Promise<void> {
    this.releaseSync(deviceId, generation);
  }

  /** `between` runs after the first write; tests use it to fail part way. */
  releaseSync(deviceId: string, generation: string, between?: () => void): void {
    this.ctx.storage.transactionSync(() => {
      if (this.kv.get<string>(`dev:${deviceId}`) !== generation) return;
      this.kv.delete(`dev:${deviceId}`);
      between?.();
      this.kv.put("count", Math.max(0, this.countSync() - 1));
    });
  }

  private get reconcileMs(): number {
    const minutes = Number(this.env.RECONCILE_MINUTES);
    return (Number.isFinite(minutes) && minutes > 0 ? minutes : 60) * 60_000;
  }

  /** The next alarm: the earliest reservation to lapse, the next reconciliation, or soon if one is part way. */
  private async schedule(now: number): Promise<void> {
    let next = this.kv.get<number>("reconcile:next");
    if (next === undefined) {
      next = now + this.reconcileMs;
      this.kv.put("reconcile:next", next);
    }
    if (this.kv.get("reconcile:started") !== undefined) next = Math.min(next, now + 1000);
    for (const [, until] of this.kv.list<number>({ prefix: "res:" })) next = Math.min(next, until + 1000);
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > next) await this.ctx.storage.setAlarm(next);
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    this.ctx.storage.transactionSync(() => this.pruneSync(now));
    const due = (this.kv.get<number>("reconcile:next") ?? 0) <= now || this.kv.get("reconcile:started") !== undefined;
    if (due) await this.reconcile();
    await this.schedule(Date.now());
  }

  /**
   * One step of reconciliation, which keeps the count self-healing whatever race left it off: walks
   * the counted devices (at most `limit` per step, resuming where the last step stopped) and asks
   * each device object whether it still holds that generation. A definite no drops the count; an
   * error or timeout keeps it for the next round. A full pass runs every RECONCILE_MINUTES (60).
   */
  private setting(name: "RECONCILE_BATCH" | "RECONCILE_CONCURRENCY", fallback: number): number {
    const n = Number(this.env[name]);
    return Number.isInteger(n) && n > 0 ? n : fallback;
  }

  async reconcile(limit = this.setting("RECONCILE_BATCH", RECONCILE_BATCH)): Promise<{ checked: number; dropped: number; kept: number; done: boolean }> {
    const now = Date.now();
    // A pass starts at its scheduled time, and the next one is due a period after that start, not
    // after the pass ends.
    if (this.kv.get("reconcile:started") === undefined) this.kv.put("reconcile:started", Math.min(this.kv.get<number>("reconcile:next") ?? now, now));
    const cursor = this.kv.get<string>("reconcile:cursor");
    const entries = [...this.kv.list<string>({ prefix: "dev:", ...(cursor ? { startAfter: cursor } : {}), limit })];
    let dropped = 0;
    let kept = 0;
    const check = async ([key, generation]: [string, string]) => {
      let holds: boolean | null;
      try {
        const stub = this.env.DEVICE.get(this.env.DEVICE.idFromName(key.slice(4)));
        holds = await Promise.race([
          stub.holds(generation),
          new Promise<null>((resolve) => setTimeout(() => resolve(null), HOLDS_TIMEOUT_MS)),
        ]);
      } catch {
        holds = null;
      }
      if (holds !== false) {
        kept++;
        return;
      }
      const removed = this.ctx.storage.transactionSync(() => {
        if (this.kv.get<string>(key) !== generation) return false;
        this.kv.delete(key);
        this.kv.put("count", Math.max(0, this.countSync() - 1));
        return true;
      });
      if (removed) dropped++;
    };
    // Bounded concurrency: a fixed number of workers take the batch's entries in turn.
    let next = 0;
    const workers = Math.min(this.setting("RECONCILE_CONCURRENCY", RECONCILE_CONCURRENCY), entries.length);
    await Promise.all(
      Array.from({ length: workers }, async () => {
        while (next < entries.length) await check(entries[next++]);
      }),
    );
    const done = entries.length < limit;
    if (done) {
      const started = this.kv.get<number>("reconcile:started") ?? now;
      this.kv.delete("reconcile:cursor");
      this.kv.delete("reconcile:started");
      this.kv.put("reconcile:next", Math.max(Date.now(), started + this.reconcileMs));
    } else {
      this.kv.put("reconcile:cursor", entries[entries.length - 1][0]);
    }
    return { checked: entries.length, dropped, kept, done };
  }

  /** Counted devices and live reservations. */
  async usage(): Promise<{ devices: number; reservations: number }> {
    const now = Date.now();
    return this.ctx.storage.transactionSync(() => ({ reservations: this.pruneSync(now).length, devices: this.countSync() }));
  }
}
