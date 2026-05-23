//// Brotli RFC 7932 word transforms (port of `c/common/transform.c`).
////
//// Applied to a dictionary word selected by a static-dictionary
//// reference; the transform_idx encodes a prefix-suffix pair, an
//// optional `OMIT_FIRST`/`OMIT_LAST` truncation, and an optional
//// `UPPERCASE_FIRST`/`UPPERCASE_ALL` case adjustment.  The RFC 7932
//// table never uses `SHIFT_FIRST` / `SHIFT_ALL` — those belong to
//// the shared-dictionary extension and are intentionally omitted.

import gleam/bit_array
import gleam/int

/// Number of transform entries (matches brotli's `kBrotliTransforms.num_transforms`).
pub const num_transforms: Int = 121

/// Raw `kPrefixSuffix` blob (216 bytes payload + 1 trailing NUL).
/// Entries are length-prefixed; offset `0xD8` (216) is the implicit
/// empty string referenced by id 49 in `transforms`, whose 0-length
/// prefix byte is exactly the trailing NUL.
pub const prefix_suffix_bytes: BitArray = <<
  1,
  32,
  2,
  44,
  32,
  8,
  32,
  111,
  102,
  32,
  116,
  104,
  101,
  32,
  4,
  32,
  111,
  102,
  32,
  2,
  115,
  32,
  1,
  46,
  5,
  32,
  97,
  110,
  100,
  32,
  4,
  32,
  105,
  110,
  32,
  1,
  34,
  4,
  32,
  116,
  111,
  32,
  2,
  34,
  62,
  1,
  10,
  2,
  46,
  32,
  1,
  93,
  5,
  32,
  102,
  111,
  114,
  32,
  3,
  32,
  97,
  32,
  6,
  32,
  116,
  104,
  97,
  116,
  32,
  1,
  39,
  6,
  32,
  119,
  105,
  116,
  104,
  32,
  6,
  32,
  102,
  114,
  111,
  109,
  32,
  4,
  32,
  98,
  121,
  32,
  1,
  40,
  6,
  46,
  32,
  84,
  104,
  101,
  32,
  4,
  32,
  111,
  110,
  32,
  4,
  32,
  97,
  115,
  32,
  4,
  32,
  105,
  115,
  32,
  4,
  105,
  110,
  103,
  32,
  2,
  10,
  9,
  1,
  58,
  3,
  101,
  100,
  32,
  2,
  61,
  34,
  4,
  32,
  97,
  116,
  32,
  3,
  108,
  121,
  32,
  1,
  44,
  2,
  61,
  39,
  5,
  46,
  99,
  111,
  109,
  47,
  7,
  46,
  32,
  84,
  104,
  105,
  115,
  32,
  5,
  32,
  110,
  111,
  116,
  32,
  3,
  101,
  114,
  32,
  3,
  97,
  108,
  32,
  4,
  102,
  117,
  108,
  32,
  4,
  105,
  118,
  101,
  32,
  5,
  108,
  101,
  115,
  115,
  32,
  4,
  101,
  115,
  116,
  32,
  4,
  105,
  122,
  101,
  32,
  2,
  194,
  160,
  4,
  111,
  117,
  115,
  32,
  5,
  32,
  116,
  104,
  101,
  32,
  2,
  101,
  32,
  0,
>>

/// Byte offset within `prefix_suffix_bytes` of the length-prefixed
/// string with the supplied id (0..49).  The id 49 names the empty
/// string and is the most common entry in `transforms`.
pub fn prefix_suffix_offset(id: Int) -> Int {
  case id {
    0 -> 0
    1 -> 2
    2 -> 5
    3 -> 14
    4 -> 19
    5 -> 22
    6 -> 24
    7 -> 30
    8 -> 35
    9 -> 37
    10 -> 42
    11 -> 45
    12 -> 47
    13 -> 50
    14 -> 52
    15 -> 58
    16 -> 62
    17 -> 69
    18 -> 71
    19 -> 78
    20 -> 85
    21 -> 90
    22 -> 92
    23 -> 99
    24 -> 104
    25 -> 109
    26 -> 114
    27 -> 119
    28 -> 122
    29 -> 124
    30 -> 128
    31 -> 131
    32 -> 136
    33 -> 140
    34 -> 142
    35 -> 145
    36 -> 151
    37 -> 159
    38 -> 165
    39 -> 169
    40 -> 173
    41 -> 178
    42 -> 183
    43 -> 189
    44 -> 194
    45 -> 199
    46 -> 202
    47 -> 207
    48 -> 213
    49 -> 216
    _ -> 0
  }
}

pub type Op {
  Identity
  OmitLast(n: Int)
  OmitFirst(n: Int)
  UppercaseFirst
  UppercaseAll
}

pub fn prefix_id_of(idx: Int) -> Int {
  case idx {
    0 -> 49
    1 -> 49
    2 -> 0
    3 -> 49
    4 -> 49
    5 -> 49
    6 -> 0
    7 -> 4
    8 -> 49
    9 -> 49
    10 -> 49
    11 -> 49
    12 -> 49
    13 -> 1
    14 -> 49
    15 -> 0
    16 -> 49
    17 -> 49
    18 -> 48
    19 -> 49
    20 -> 49
    21 -> 49
    22 -> 49
    23 -> 49
    24 -> 49
    25 -> 49
    26 -> 49
    27 -> 49
    28 -> 49
    29 -> 49
    30 -> 0
    31 -> 49
    32 -> 5
    33 -> 0
    34 -> 49
    35 -> 49
    36 -> 49
    37 -> 49
    38 -> 49
    39 -> 49
    40 -> 49
    41 -> 47
    42 -> 49
    43 -> 49
    44 -> 49
    45 -> 49
    46 -> 49
    47 -> 49
    48 -> 49
    49 -> 49
    50 -> 49
    51 -> 49
    52 -> 0
    53 -> 49
    54 -> 49
    55 -> 49
    56 -> 49
    57 -> 49
    58 -> 49
    59 -> 49
    60 -> 49
    61 -> 49
    62 -> 47
    63 -> 49
    64 -> 49
    65 -> 0
    66 -> 49
    67 -> 5
    68 -> 49
    69 -> 49
    70 -> 49
    71 -> 0
    72 -> 35
    73 -> 47
    74 -> 49
    75 -> 49
    76 -> 49
    77 -> 5
    78 -> 49
    79 -> 49
    80 -> 49
    81 -> 0
    82 -> 49
    83 -> 0
    84 -> 49
    85 -> 0
    86 -> 49
    87 -> 49
    88 -> 49
    89 -> 0
    90 -> 49
    91 -> 0
    92 -> 49
    93 -> 49
    94 -> 49
    95 -> 49
    96 -> 0
    97 -> 49
    98 -> 0
    99 -> 49
    100 -> 49
    101 -> 49
    102 -> 45
    103 -> 0
    104 -> 49
    105 -> 49
    106 -> 49
    107 -> 49
    108 -> 49
    109 -> 0
    110 -> 0
    111 -> 0
    112 -> 49
    113 -> 49
    114 -> 49
    115 -> 0
    116 -> 49
    117 -> 0
    118 -> 0
    119 -> 0
    120 -> 0
    _ -> 49
  }
}

pub fn suffix_id_of(idx: Int) -> Int {
  case idx {
    0 -> 49
    1 -> 0
    2 -> 0
    3 -> 49
    4 -> 0
    5 -> 47
    6 -> 49
    7 -> 0
    8 -> 3
    9 -> 49
    10 -> 6
    11 -> 49
    12 -> 49
    13 -> 0
    14 -> 1
    15 -> 0
    16 -> 7
    17 -> 9
    18 -> 0
    19 -> 8
    20 -> 5
    21 -> 10
    22 -> 11
    23 -> 49
    24 -> 13
    25 -> 14
    26 -> 49
    27 -> 49
    28 -> 15
    29 -> 16
    30 -> 49
    31 -> 12
    32 -> 49
    33 -> 1
    34 -> 49
    35 -> 18
    36 -> 17
    37 -> 19
    38 -> 20
    39 -> 49
    40 -> 49
    41 -> 49
    42 -> 49
    43 -> 22
    44 -> 49
    45 -> 23
    46 -> 24
    47 -> 25
    48 -> 49
    49 -> 26
    50 -> 27
    51 -> 28
    52 -> 12
    53 -> 29
    54 -> 49
    55 -> 49
    56 -> 49
    57 -> 21
    58 -> 1
    59 -> 49
    60 -> 31
    61 -> 32
    62 -> 3
    63 -> 49
    64 -> 49
    65 -> 1
    66 -> 8
    67 -> 21
    68 -> 0
    69 -> 10
    70 -> 30
    71 -> 5
    72 -> 49
    73 -> 2
    74 -> 17
    75 -> 36
    76 -> 33
    77 -> 0
    78 -> 21
    79 -> 5
    80 -> 37
    81 -> 30
    82 -> 38
    83 -> 0
    84 -> 39
    85 -> 49
    86 -> 34
    87 -> 8
    88 -> 12
    89 -> 21
    90 -> 40
    91 -> 12
    92 -> 41
    93 -> 42
    94 -> 17
    95 -> 43
    96 -> 5
    97 -> 10
    98 -> 34
    99 -> 33
    100 -> 44
    101 -> 5
    102 -> 49
    103 -> 33
    104 -> 30
    105 -> 30
    106 -> 46
    107 -> 1
    108 -> 34
    109 -> 33
    110 -> 30
    111 -> 1
    112 -> 33
    113 -> 21
    114 -> 12
    115 -> 5
    116 -> 34
    117 -> 12
    118 -> 30
    119 -> 34
    120 -> 34
    _ -> 49
  }
}

pub fn op_of(idx: Int) -> Op {
  case idx {
    0 -> Identity
    1 -> Identity
    2 -> Identity
    3 -> OmitFirst(1)
    4 -> UppercaseFirst
    5 -> Identity
    6 -> Identity
    7 -> Identity
    8 -> Identity
    9 -> UppercaseFirst
    10 -> Identity
    11 -> OmitFirst(2)
    12 -> OmitLast(1)
    13 -> Identity
    14 -> Identity
    15 -> UppercaseFirst
    16 -> Identity
    17 -> Identity
    18 -> Identity
    19 -> Identity
    20 -> Identity
    21 -> Identity
    22 -> Identity
    23 -> OmitLast(3)
    24 -> Identity
    25 -> Identity
    26 -> OmitFirst(3)
    27 -> OmitLast(2)
    28 -> Identity
    29 -> Identity
    30 -> UppercaseFirst
    31 -> Identity
    32 -> Identity
    33 -> Identity
    34 -> OmitFirst(4)
    35 -> Identity
    36 -> Identity
    37 -> Identity
    38 -> Identity
    39 -> OmitFirst(5)
    40 -> OmitFirst(6)
    41 -> Identity
    42 -> OmitLast(4)
    43 -> Identity
    44 -> UppercaseAll
    45 -> Identity
    46 -> Identity
    47 -> Identity
    48 -> OmitLast(7)
    49 -> OmitLast(1)
    50 -> Identity
    51 -> Identity
    52 -> Identity
    53 -> Identity
    54 -> OmitFirst(9)
    55 -> OmitFirst(7)
    56 -> OmitLast(6)
    57 -> Identity
    58 -> UppercaseFirst
    59 -> OmitLast(8)
    60 -> Identity
    61 -> Identity
    62 -> Identity
    63 -> OmitLast(5)
    64 -> OmitLast(9)
    65 -> UppercaseFirst
    66 -> UppercaseFirst
    67 -> Identity
    68 -> UppercaseAll
    69 -> UppercaseFirst
    70 -> Identity
    71 -> Identity
    72 -> Identity
    73 -> Identity
    74 -> UppercaseFirst
    75 -> Identity
    76 -> Identity
    77 -> Identity
    78 -> UppercaseFirst
    79 -> UppercaseFirst
    80 -> Identity
    81 -> Identity
    82 -> Identity
    83 -> UppercaseAll
    84 -> Identity
    85 -> UppercaseAll
    86 -> Identity
    87 -> UppercaseAll
    88 -> UppercaseFirst
    89 -> Identity
    90 -> Identity
    91 -> UppercaseFirst
    92 -> Identity
    93 -> Identity
    94 -> UppercaseAll
    95 -> Identity
    96 -> UppercaseFirst
    97 -> UppercaseAll
    98 -> Identity
    99 -> UppercaseFirst
    100 -> Identity
    101 -> UppercaseAll
    102 -> Identity
    103 -> Identity
    104 -> UppercaseFirst
    105 -> UppercaseAll
    106 -> Identity
    107 -> UppercaseAll
    108 -> UppercaseFirst
    109 -> UppercaseFirst
    110 -> UppercaseAll
    111 -> UppercaseAll
    112 -> UppercaseAll
    113 -> UppercaseAll
    114 -> UppercaseAll
    115 -> UppercaseAll
    116 -> UppercaseAll
    117 -> UppercaseAll
    118 -> UppercaseFirst
    119 -> UppercaseAll
    120 -> UppercaseFirst
    _ -> Identity
  }
}

/// Apply transform `idx` to the dictionary `word` (its full byte
/// slice).  Returns the prefix + (optionally truncated and
/// case-adjusted) word + suffix.
pub fn apply(word: BitArray, idx: Int) -> BitArray {
  let prefix = prefix_suffix_slice(prefix_id_of(idx))
  let suffix = prefix_suffix_slice(suffix_id_of(idx))
  let body = apply_op(word, op_of(idx))
  bit_array.concat([prefix, body, suffix])
}

fn prefix_suffix_slice(id: Int) -> BitArray {
  let start = prefix_suffix_offset(id)
  let assert Ok(len_bits) = bit_array.slice(prefix_suffix_bytes, start, 1)
  let len = case len_bits {
    <<n>> -> n
    _ -> 0
  }
  case len {
    0 -> <<>>
    _ -> {
      let assert Ok(payload) =
        bit_array.slice(prefix_suffix_bytes, start + 1, len)
      payload
    }
  }
}

fn apply_op(word: BitArray, op: Op) -> BitArray {
  let len = bit_array.byte_size(word)
  case op {
    Identity -> word
    OmitLast(n) ->
      case n >= len {
        True -> <<>>
        False -> {
          let assert Ok(slice) = bit_array.slice(word, 0, len - n)
          slice
        }
      }
    OmitFirst(n) ->
      case n >= len {
        True -> <<>>
        False -> {
          let assert Ok(slice) = bit_array.slice(word, n, len - n)
          slice
        }
      }
    UppercaseFirst -> uppercase_first(word, len)
    UppercaseAll -> uppercase_all(word, 0, len)
  }
}

/// `ToUpperCase` from brotli C: ASCII case-flip on a..z; for 2-byte
/// UTF-8 (0xC0..0xDF lead) flip bit 5 of the trailing byte; for
/// 3-byte UTF-8 (0xE0..0xEF lead) flip bit 0 of the third byte
/// (matches brotli's "arbitrary 3-byte transform").
fn uppercase_first(word: BitArray, len: Int) -> BitArray {
  case word {
    <<>> -> <<>>
    <<b, rest:bytes>> if b < 0xC0 -> {
      let new_b = case b >= 0x61 && b <= 0x7A {
        True -> int.bitwise_exclusive_or(b, 32)
        False -> b
      }
      <<new_b, rest:bits>>
    }
    <<b, c, rest:bytes>> if b < 0xE0 -> {
      let _ = len
      <<b, int.bitwise_exclusive_or(c, 32), rest:bits>>
    }
    <<b, c, d, rest:bytes>> -> {
      let _ = len
      <<b, c, int.bitwise_exclusive_or(d, 5), rest:bits>>
    }
    _ -> word
  }
}

fn uppercase_all(word: BitArray, taken: Int, total: Int) -> BitArray {
  case taken >= total {
    True -> word
    False -> {
      let assert Ok(head) = bit_array.slice(word, 0, taken)
      let assert Ok(tail) = bit_array.slice(word, taken, total - taken)
      let new_tail = uppercase_first(tail, total - taken)
      let step = uppercase_step(tail)
      uppercase_all(bit_array.concat([head, new_tail]), taken + step, total)
    }
  }
}

fn uppercase_step(rest: BitArray) -> Int {
  case rest {
    <<b, _:bits>> if b < 0xC0 -> 1
    <<b, _:bits>> if b < 0xE0 -> 2
    _ -> 3
  }
}
