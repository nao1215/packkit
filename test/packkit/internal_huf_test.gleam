//// Unit tests for the Huffman literal decoder.  These build the
//// tree from hand-chosen weights and decode hand-constructed
//// bitstreams so the table builder + bitstream walker are
//// verified independently of zstd's end-to-end pipeline.

import gleeunit/should
import packkit/internal/huf

pub fn build_tree_minimal_alphabet_test() -> Nil {
  // Direct-weight header byte 129 -> num_symbols = 2 (one
  // transmitted weight + one implied last weight).  weights byte
  // 0x10 unpacks to [1, 0]: symbol 0 has weight 1, symbol 1 is
  // absent.  The implied last weight then attaches to symbol 2.
  //   sum = 2^(1-1) = 1; max_bits = highBit(1) + 1 = 1
  //   rest = 2 - 1 = 1; verif = 1 << highBit(1) = 1; last = 1
  //   Final weights: [1, 0, 1]; both present symbols have
  //   code length 1; max_bits = 1.
  let assert Ok(#(tree, consumed)) = huf.read_tree(<<0x81, 0x10>>)
  consumed |> should.equal(2)
  tree.max_bits |> should.equal(1)
}

pub fn decode_stream_two_symbol_alphabet_test() -> Nil {
  // Same tree as build_tree_minimal_alphabet_test: symbols 0 and
  // 2 each have code length 1 (codes 0 and 1).
  let assert Ok(#(tree, _consumed)) = huf.read_tree(<<0x81, 0x10>>)
  // Hand-built bitstream: the symbols [0, 2, 0, 2, 0] need 5 bits
  // (0 1 0 1 0).  Backward reader reads MSB-first BELOW the
  // highest set bit (the stream marker).  Pack them into one byte
  // as 0b00_1_01010 — the marker at position 5, the 5 content
  // bits 01010 below.  That byte is 0x2A.
  let bitstream = <<0x2A>>
  let assert Ok(decoded) = huf.decode_stream(tree, bitstream, 5)
  decoded
  |> should.equal(<<0, 2, 0, 2, 0>>)
}

pub fn build_tree_balanced_four_symbols_test() -> Nil {
  // header_byte 131 -> num_symbols = 4 (3 transmitted + 1 implied)
  // weights packed in 2 bytes: 0x22 0x20 -> [2, 2, 2, ?]
  //   sum(2^(2-1)) * 3 = 6, max_bits = highBit(6)+1 = 2+1 = 3
  //   rest = 8 - 6 = 2, last_weight = highBit(2)+1 = 1+1 = 2
  //   But last weight should make `rest` a clean power of 2 →
  //   verif=2, rest=2 ✓.  All four weights = 2.
  //   Each symbol gets bits = 3+1-2 = 2 → 4 codes of length 2.
  let assert Ok(#(tree, consumed)) = huf.read_tree(<<0x83, 0x22, 0x20>>)
  consumed |> should.equal(3)
  // max_bits should be 3 (one more than highest weight).
  case tree {
    huf.Tree(max_bits: 3, lookup: _) -> Nil
    _ -> should.fail()
  }
}
