//! deflate_slow — the zlib 1.2.3 variant.
//!
//! Differences from zlib >= 1.2.4 (`slow.zig`) that matter for the
//! compressed output:
//!   * the strategy dispatch lives INSIDE this function: Z_HUFFMAN_ONLY
//!     skips the match search entirely, Z_RLE only looks for distance-1
//!     matches via `longest_match_fast`;
//!   * `hash_head` is NOT re-initialized on every loop iteration;
//!   * the tail does not carry the 1.2.6+ `insert` bookkeeping (the insert
//!     field does not exist in 1.2.3; it is only observable across
//!     intermediate flushes, which the wrapper call pattern never performs).

const st = @import("state.zig");
const trees = @import("trees.zig");

const DeflateState = st.DeflateState;
const BlockState = st.BlockState;
const MIN_MATCH = st.MIN_MATCH;
const MIN_LOOKAHEAD = st.MIN_LOOKAHEAD;
const NIL = st.NIL;
const TOO_FAR = st.TOO_FAR;
const Z_FILTERED = st.Z_FILTERED;
const Z_HUFFMAN_ONLY = st.Z_HUFFMAN_ONLY;
const Z_RLE = st.Z_RLE;
const Z_NO_FLUSH = st.Z_NO_FLUSH;
const Z_FINISH = st.Z_FINISH;

pub fn deflateSlow(s: *DeflateState, flush: u32) BlockState {
    var hash_head: u32 = NIL; // head of hash chain (kept across iterations)
    var bflush: bool = false; // set if current block must be flushed

    // Process the input block.
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
        if (s.lookahead >= MIN_MATCH) {
            hash_head = s.insertString(s.strstart);
        }

        // Find the longest match, discarding those <= prev_length.
        s.prev_length = s.match_length;
        s.prev_match = s.match_start;
        s.match_length = MIN_MATCH - 1;

        if (hash_head != NIL and s.prev_length < s.max_lazy and
            s.strstart - hash_head <= s.maxDist())
        {
            if (s.strategy != Z_HUFFMAN_ONLY and s.strategy != Z_RLE) {
                s.match_length = s.longestMatch(hash_head);
            } else if (s.strategy == Z_RLE and s.strstart - hash_head == 1) {
                s.match_length = s.longestMatchFast(hash_head);
            }
            // longest_match()/longest_match_fast() set match_start

            if (s.match_length <= 5 and (s.strategy == Z_FILTERED or
                (s.match_length == MIN_MATCH and s.strstart - s.match_start > TOO_FAR)))
            {
                s.match_length = MIN_MATCH - 1;
            }
        }
        // If there was a match at the previous step and the current match is
        // not better, output the previous match:
        if (s.prev_length >= MIN_MATCH and s.match_length <= s.prev_length) {
            const max_insert = s.strstart + s.lookahead - MIN_MATCH;

            bflush = trees.trTally(s, s.strstart - 1 - s.prev_match, s.prev_length - MIN_MATCH);

            s.lookahead -= s.prev_length - 1;
            s.prev_length -= 2;
            while (true) {
                s.strstart += 1;
                if (s.strstart <= max_insert) {
                    _ = s.insertString(s.strstart);
                }
                s.prev_length -= 1;
                if (s.prev_length == 0) break;
            }
            s.match_available = false;
            s.match_length = MIN_MATCH - 1;
            s.strstart += 1;

            if (bflush) {
                if (s.flushBlock(false)) |bs| return bs;
            }
        } else if (s.match_available) {
            bflush = trees.trTally(s, 0, s.window[s.strstart - 1]);
            if (bflush) {
                s.flushBlockOnlyNoExit(false);
            }
            s.strstart += 1;
            s.lookahead -= 1;
            if (s.avail_out == 0) return .need_more;
        } else {
            s.match_available = true;
            s.strstart += 1;
            s.lookahead -= 1;
        }
    }
    if (s.match_available) {
        _ = trees.trTally(s, 0, s.window[s.strstart - 1]);
        s.match_available = false;
    }
    if (flush == Z_FINISH) {
        if (s.flushBlock(true)) |bs| return bs;
        return .finish_done;
    }
    return .block_done;
}
