// The relay's memory budget. It is module state, so it covers every device object that shares
// this isolate (Cloudflare may run several in one, under one 128 MB limit). Everything the relay
// holds that grows with traffic is charged here first: request bodies on their way to the Mac
// (with their base64 and frame copies), bodies sent and not yet acknowledged, inline answers, and
// streamed answers queued for a slow client. A charge that doesn't fit is refused, never forced.

import { LIMITS } from "./protocol";

let used = 0;
let limit: number = LIMITS.memoryBudgetBytes;

export const budget = {
  get used(): number {
    return used;
  },
  get limit(): number {
    return limit;
  },
  /** Charges `bytes` if they fit; returns whether they did. */
  reserve(bytes: number): boolean {
    if (bytes < 0 || used + bytes > limit) return false;
    used += bytes;
    return true;
  },
  release(bytes: number): void {
    used = Math.max(0, used - bytes);
  },
  /** For tests. */
  setLimit(bytes: number): void {
    limit = bytes;
  },
};

/** What holding `bytes` of body costs while it is encoded and framed: the bytes, their base64, and the frame. */
export function encodeCost(bytes: number): number {
  return bytes + 2 * Math.ceil((bytes * 4) / 3) + 512;
}
