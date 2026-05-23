//// Tripwires for known brotli decoder bugs found via differential
//// testing against the system `brotli` CLI.  Each test asserts the
//// CURRENT (wrong) behavior so we notice immediately when a future
//// change either fixes or regresses the symptom.  When a fix is
//// pushed, update the asserted error to the expected `Ok(...)` so
//// the test continues to guard against regressions.
////
//// See `~/Desktop/gleam-dig-bug-packkit-20260523-200000/findings.md`
//// (gleam-dig-bug session, 2026-05-23) for the investigation.

import gleam/bit_array
import gleeunit/should
import packkit/brotli
import packkit/error

/// Bug #1 — `printf 'users":[{"name":"alice","age":30,"email":"alice@example.com","active":true,"score":99.5},{"name":"bob","age":25,"email":"bob@example.com","active":false,"s' | brotli -c`
/// triggers a context-map zero-run overrun in `decode_context_map`.
/// Smaller and larger variants of the same JSON shape decode cleanly;
/// the trigger is brotli's specific (NTREESL, RLEMAX) choice for this
/// exact 155-byte input.  Likely an off-by-one in either the prefix-code
/// symbol decoding for the context-map alphabet, or the map-size /
/// position tracking around the RLE-zero-run extra-bits read.
pub fn bug1_context_map_zero_run_overrun_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1F9A00208CD315F3A384710FA29DD37EB324FAE137CB6E7A424A198C522C3A3A39A103D25BD2A2E2204C2409C0F21C5E5CBB152D983E2C0FAB17B1BD5A07363B5370FCAC9AE70D70EC8990605D46998BAA5E3ECFAAA7125144B95C0FDB17",
    )
  brotli.decode(bytes: input)
  |> should.equal(
    Error(error.CodecInvalidData(
      message: "brotli context-map zero run overruns map size",
    )),
  )
}
