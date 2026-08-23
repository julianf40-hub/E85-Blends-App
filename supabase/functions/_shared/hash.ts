// 85Blends 2.3.0 — Phase B1. Raw-body content hashing for the webhook ledger's payload_hash.
//
// Pure Web Crypto — same portability note as hmac.ts: no Deno-specific APIs, runs under Node too.

function bytesToHex(bytes: Uint8Array): string {
  let hex = "";
  for (const byte of bytes) {
    hex += byte.toString(16).padStart(2, "0");
  }
  return hex;
}

/** SHA-256 of the exact raw request bytes, lowercase hex — stored as private.revenuecat_webhook_events.payload_hash. */
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  // `as BufferSource`: TypeScript's DOM lib types `Uint8Array` as generic over its backing buffer
  // (`Uint8Array<ArrayBufferLike>`) while `SubtleCrypto.digest` still expects the narrower
  // `ArrayBufferView<ArrayBuffer>` shape — a type-level mismatch only, not a runtime one (a plain
  // `Uint8Array` is always a valid BufferSource at runtime, in both Deno and Node).
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return bytesToHex(new Uint8Array(digest));
}
