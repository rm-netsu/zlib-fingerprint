//! deflate_huff — zlib's literals-only block-state function (strategy
//! Z_HUFFMAN_ONLY).
//!
//! Port of zlib >= 1.2.4, where the dedicated function replaced the 1.2.3
//! approach of running deflate_fast/deflate_slow with the match search
//! disabled (see `fast_1_2_3.zig`/`slow_1_2_3.zig`). The different
//! fill_window timing (lookahead == 0 instead of < MIN_LOOKAHEAD) is what
//! makes 1.2.4+ HUFFMAN_ONLY streams differ from 1.2.3 ones.

const st = @import("state.zig");
const trees = @import("trees.zig");

const DeflateState = st.DeflateState;
const BlockState = st.BlockState;
const Z_NO_FLUSH = st.Z_NO_FLUSH;
const Z_FINISH = st.Z_FINISH;

pub fn deflateHuff(s: *DeflateState, flush: u32) BlockState {
    var bflush: bool = false; // set if current block must be flushed

    while (true) {
        // Make sure that we have a literal to write.
        if (s.lookahead == 0) {
            s.fillWindow();
            if (s.lookahead == 0) {
                if (flush == Z_NO_FLUSH) return .need_more;
                break; // flush the current block
            }
        }

        // Output a literal byte.
        s.match_length = 0;
        bflush = trees.trTally(s, 0, s.window[s.strstart]);
        s.lookahead -= 1;
        s.strstart += 1;
        if (bflush) {
            if (s.flushBlock(false)) |bs| return bs;
        }
    }
    s.insert = 0;
    if (flush == Z_FINISH) {
        if (s.flushBlock(true)) |bs| return bs;
        return .finish_done;
    }
    if (s.sym_next != 0) {
        if (s.flushBlock(false)) |bs| return bs;
    }
    return .block_done;
}
