//! deflate_rle — zlib's run-length block-state function (strategy Z_RLE).
//!
//! Port of zlib >= 1.2.4, where the dedicated run scanner replaced the
//! 1.2.3 hash-based approach (see `fast_1_2_3.zig`/`slow_1_2_3.zig` for the
//! 1.2.3 behavior).

const st = @import("state.zig");
const trees = @import("trees.zig");

const DeflateState = st.DeflateState;
const BlockState = st.BlockState;
const MIN_MATCH = st.MIN_MATCH;
const MAX_MATCH = st.MAX_MATCH;
const Z_NO_FLUSH = st.Z_NO_FLUSH;
const Z_FINISH = st.Z_FINISH;

pub fn deflateRle(s: *DeflateState, flush: u32) BlockState {
    var bflush: bool = false; // set if current block must be flushed

    while (true) {
        // Make sure that we always have enough lookahead, except at the end
        // of the input file. We need MAX_MATCH bytes for the longest run,
        // plus one for the unrolled loop.
        if (s.lookahead <= MAX_MATCH) {
            s.fillWindow();
            if (s.lookahead <= MAX_MATCH and flush == Z_NO_FLUSH) {
                return .need_more;
            }
            if (s.lookahead == 0) break; // flush the current block
        }

        // See how many times the previous byte repeats.
        s.match_length = 0;
        if (s.lookahead >= MIN_MATCH and s.strstart > 0) {
            var scan: usize = @as(usize, s.strstart) - 1;
            const prev_byte = s.window[scan];
            scan += 1;
            if (prev_byte == s.window[scan]) {
                scan += 1;
                if (prev_byte == s.window[scan]) {
                    scan += 1;
                    if (prev_byte == s.window[scan]) {
                        // The 8-per-iteration unrolled run scan; the cursor
                        // ends ON the first differing byte or past strend.
                        const strend: usize = @as(usize, s.strstart) + MAX_MATCH;
                        while (true) {
                            if (prev_byte != s.window[scan + 1]) { scan += 1; break; }
                            if (prev_byte != s.window[scan + 2]) { scan += 2; break; }
                            if (prev_byte != s.window[scan + 3]) { scan += 3; break; }
                            if (prev_byte != s.window[scan + 4]) { scan += 4; break; }
                            if (prev_byte != s.window[scan + 5]) { scan += 5; break; }
                            if (prev_byte != s.window[scan + 6]) { scan += 6; break; }
                            if (prev_byte != s.window[scan + 7]) { scan += 7; break; }
                            if (prev_byte != s.window[scan + 8]) { scan += 8; break; }
                            scan += 8;
                            if (!(scan < strend)) break;
                        }
                        s.match_length = @intCast(@as(i64, MAX_MATCH) - (@as(i64, @intCast(strend)) - @as(i64, @intCast(scan))));
                        if (s.match_length > s.lookahead) s.match_length = s.lookahead;
                    }
                }
            }
        }

        // Emit match if have run of MIN_MATCH or longer, else emit literal.
        if (s.match_length >= MIN_MATCH) {
            bflush = trees.trTally(s, 1, s.match_length - MIN_MATCH);
            s.lookahead -= s.match_length;
            s.strstart += s.match_length;
            s.match_length = 0;
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
