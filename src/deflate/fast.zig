//! deflate_fast — zlib's fast block-state function (levels 1-3).
//!
//! Port of zlib >= 1.2.4 (the strategy dispatch moved out of this function
//! in 1.2.4; `hash_head` is re-initialized on every iteration). zlib 1.2.3
//! has its own variant in `fast_1_2_3.zig`.

const st = @import("state.zig");
const trees = @import("trees.zig");

const DeflateState = st.DeflateState;
const BlockState = st.BlockState;
const MIN_MATCH = st.MIN_MATCH;
const MIN_LOOKAHEAD = st.MIN_LOOKAHEAD;
const NIL = st.NIL;
const Z_NO_FLUSH = st.Z_NO_FLUSH;
const Z_FINISH = st.Z_FINISH;

pub fn deflateFast(s: *DeflateState, flush: u32) BlockState {
    var hash_head: u32 = NIL; // head of the hash chain
    var bflush: bool = false; // set if current block must be flushed

    while (true) {
        // Make sure that we always have enough lookahead, except at the end
        // of the input file.
        if (s.lookahead < MIN_LOOKAHEAD) {
            s.fillWindow();
            if (s.lookahead < MIN_LOOKAHEAD and flush == Z_NO_FLUSH) {
                return .need_more;
            }
            if (s.lookahead == 0) break; // flush the current block
        }

        // Insert the string window[strstart .. strstart+2] in the
        // dictionary, and set hash_head to the head of the hash chain.
        hash_head = NIL;
        if (s.lookahead >= MIN_MATCH) {
            hash_head = s.insertString(s.strstart);
        }

        // Find the longest match, discarding those <= prev_length.
        if (hash_head != NIL and s.strstart - hash_head <= s.maxDist()) {
            s.match_length = s.longestMatch(hash_head);
            // longest_match sets match_start
        }
        if (s.match_length >= MIN_MATCH) {
            bflush = trees.trTally(s, s.strstart - s.match_start, s.match_length - MIN_MATCH);
            s.lookahead -= s.match_length;

            // Insert new strings in the hash table only if the match length
            // is not too large. This saves time but degrades compression.
            if (s.match_length <= s.max_lazy and s.lookahead >= MIN_MATCH) {
                s.match_length -= 1; // string at strstart already in table
                while (true) {
                    s.strstart += 1;
                    _ = s.insertString(s.strstart);
                    s.match_length -= 1;
                    if (s.match_length == 0) break;
                }
                s.strstart += 1;
            } else {
                s.strstart += s.match_length;
                s.match_length = 0;
                s.ins_h = s.window[s.strstart];
                s.updateHash(s.window[s.strstart + 1]);
                // If lookahead < MIN_MATCH, ins_h is garbage, but it does
                // not matter since it will be recomputed at next call.
            }
        } else {
            // No match, output a literal byte.
            bflush = trees.trTally(s, 0, s.window[s.strstart]);
            s.lookahead -= 1;
            s.strstart += 1;
        }
        if (bflush) {
            if (s.flushBlock(false)) |bs| return bs;
        }
    }
    s.insert = if (s.strstart < MIN_MATCH - 1) s.strstart else MIN_MATCH - 1;
    if (flush == Z_FINISH) {
        if (s.flushBlock(true)) |bs| return bs;
        return .finish_done;
    }
    if (s.sym_next != 0) {
        if (s.flushBlock(false)) |bs| return bs;
    }
    return .block_done;
}
