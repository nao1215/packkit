// Reference implementations for test/packkit_reference_differential_test.gleam:
// Node's zlib and crypto. Bytes cross the boundary as upper-case hex strings
// so this file does not depend on the runtime representation of Gleam bit
// arrays.
import * as zlib from "node:zlib";
import * as crypto from "node:crypto";
import { Ok, Error } from "./gleam.mjs";

const unhex = (h) => Buffer.from(h, "hex");
const hex = (b) => Buffer.from(b).toString("hex").toUpperCase();

function guard(f) {
  try {
    return new Ok(hex(f()));
  } catch {
    return new Error(undefined);
  }
}

export const zlib_compress = (h) => hex(zlib.deflateSync(unhex(h)));
export const zlib_uncompress = (h) => guard(() => zlib.inflateSync(unhex(h)));
export const gzip = (h) => hex(zlib.gzipSync(unhex(h)));
export const gunzip = (h) => guard(() => zlib.gunzipSync(unhex(h)));
export const raw_deflate = (h) => hex(zlib.deflateRawSync(unhex(h)));
export const raw_inflate = (h) => guard(() => zlib.inflateRawSync(unhex(h)));
export const crc32 = (h) => zlib.crc32(unhex(h));

export function adler32(h) {
  // Node has no adler32; RFC 1950 section 8.2, written out.
  let a = 1;
  let b = 0;
  for (const byte of unhex(h)) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return b * 65536 + a;
}

export const sha256 = (h) =>
  hex(crypto.createHash("sha256").update(unhex(h)).digest());
export const sha1 = (h) =>
  hex(crypto.createHash("sha1").update(unhex(h)).digest());
export const hmac_sha1 = (k, d) =>
  hex(crypto.createHmac("sha1", unhex(k)).update(unhex(d)).digest());
export const pbkdf2_hmac_sha1 = (p, s, iter, len) =>
  hex(crypto.pbkdf2Sync(unhex(p), unhex(s), iter, len, "sha1"));
