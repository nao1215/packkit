%% Reference implementations for test/packkit_reference_differential_test.gleam:
%% OTP's zlib, erlang:crc32 / adler32 and crypto. Bytes cross the boundary
%% as upper-case hex strings so the JavaScript side does not depend on the
%% runtime representation of Gleam bit arrays.
-module(packkit_reference_ffi).
-export([zlib_compress/1, zlib_uncompress/1, gzip/1, gunzip/1,
         raw_deflate/1, raw_inflate/1, crc32/1, adler32/1, sha256/1,
         hmac_sha1/2, pbkdf2_hmac_sha1/4]).

hex(B) -> binary:encode_hex(B).
unhex(H) -> binary:decode_hex(H).

guard(F) ->
    try {ok, hex(F())}
    catch _:_ -> {error, nil}
    end.

zlib_compress(H) -> hex(zlib:compress(unhex(H))).
zlib_uncompress(H) -> guard(fun() -> zlib:uncompress(unhex(H)) end).
gzip(H) -> hex(zlib:gzip(unhex(H))).
gunzip(H) -> guard(fun() -> zlib:gunzip(unhex(H)) end).
raw_deflate(H) -> hex(zlib:zip(unhex(H))).
raw_inflate(H) -> guard(fun() -> zlib:unzip(unhex(H)) end).
crc32(H) -> erlang:crc32(unhex(H)).
adler32(H) -> erlang:adler32(unhex(H)).
sha256(H) -> hex(crypto:hash(sha256, unhex(H))).
hmac_sha1(K, D) -> hex(crypto:mac(hmac, sha, unhex(K), unhex(D))).
pbkdf2_hmac_sha1(P, S, Iter, Len) ->
    hex(crypto:pbkdf2_hmac(sha, unhex(P), unhex(S), Iter, Len)).
