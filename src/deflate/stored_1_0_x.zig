//! deflate_stored — the zlib 1.0.1 .. 1.0.5 variant (class A, level 0).
//!
//! Ported faithfully from the 1.0.5 vendor C source. Unlike every later
//! generation, this one does not consult `pending_buf_size` at all:
//!   * `strstart` is clamped to 0xffff (with the leftover pushed back into
//!     `lookahead`) but NO block is emitted at the clamp;
//!   * a block is flushed only when `strstart - block_start` reaches
//!     MAX_DIST(s) — at windowBits 15 the first fill already jumps strstart
//!     to 65536, so the first block is the full 65535 bytes (the real
//!     1.0.5 thereby overruns its pending buffer by 4 bytes at memLevel 8;
//!     this port has explicit headroom and models the emitted bytes);
//!   * MAX_DIST is evaluated in unsigned arithmetic: at windowBits 8
//!     (w_size 256 < MIN_LOOKAHEAD 262) it underflows and the mid-loop
//!     flush never fires — the window keeps sliding (slide threshold 250)
//!     with `block_start` going negative until the final flush, which then
//!     emits an empty static-Huffman block because the stored-source
//!     pointer is NULL. The historical 1.0.5 really does lose the data this
//!     way; the port reproduces those (corrupt but deterministic) bytes.
//!
//! The final FLUSH_BLOCK is unconditional in 1.0.x (no `strstart >
//! block_start` guard, which only arrived with 1.2.6).

const st = @import("state.zig");

const DeflateState = st.DeflateState;
const BlockState = st.BlockState;
const Z_NO_FLUSH = st.Z_NO_FLUSH;
const Z_FINISH = st.Z_FINISH;

pub fn deflateStored10x(s: *DeflateState, flush: u32) BlockState {
    while (true) {
        // Fill the window as much as possible.
        if (s.lookahead <= 1) {
            s.fillWindow();
            if (s.lookahead == 0 and flush == Z_NO_FLUSH) return .need_more;

            if (s.lookahead == 0) break; // flush the current block
        }

        s.strstart += s.lookahead;
        s.lookahead = 0;

        // Stored blocks are limited to 0xffff bytes.
        if (s.strstart == 0 or s.strstart > 0xfffe) {
            // strstart == 0 is possible when wraparound on 16-bit machine.
            s.lookahead = s.strstart -% 0xffff;
            s.strstart = 0xffff;
        }

        // Emit a stored block if it is large enough. (uInt)block_start of a
        // negative block_start wraps exactly like the C cast.
        const span: u32 = s.strstart -% @as(u32, @truncate(@as(u64, @bitCast(s.block_start))));
        if (span >= s.maxDist()) {
            if (s.flushBlock(false)) |bs| return bs;
        }
    }
    const last = flush == Z_FINISH;
    if (s.flushBlock(last)) |bs| return bs;
    return if (last) .finish_done else .block_done;
}
