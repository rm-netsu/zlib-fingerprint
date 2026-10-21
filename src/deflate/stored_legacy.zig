//! deflate_stored — the zlib 1.2.3 .. 1.2.8 variant (level 0).
//!
//! Blocks are emitted through the pending buffer with
//! `max_block_size = min(0xffff, lit_bufsize*4 - 5)`, i.e. the block size
//! depends on memLevel. A block is emitted whenever the window grows past
//! `block_start + max_block_size` or when `strstart - block_start` reaches
//! MAX_DIST. The 1.2.6+ tail (skip flushing an empty block on non-finish
//! flushes) is used; it is output-identical to the 1.2.3-1.2.5 tail for the
//! Z_NO_FLUSH / Z_FINISH call pattern of the compressor wrappers.

const st = @import("state.zig");

const DeflateState = st.DeflateState;
const BlockState = st.BlockState;
const Z_NO_FLUSH = st.Z_NO_FLUSH;
const Z_FINISH = st.Z_FINISH;

pub fn deflateStoredLegacy(s: *DeflateState, flush: u32) BlockState {
    // Stored blocks are limited to 0xffff bytes, pending_buf is limited to
    // pending_buf_size, and each stored block has a 5 byte header.
    var max_block_size: u64 = 0xffff;
    if (max_block_size > s.pending_buf_size - 5) {
        max_block_size = s.pending_buf_size - 5;
    }

    // Copy as much as possible from input to output.
    while (true) {
        // Fill the window as much as possible.
        if (s.lookahead <= 1) {
            s.fillWindow();
            if (s.lookahead == 0 and flush == Z_NO_FLUSH) return .need_more;

            if (s.lookahead == 0) break; // flush the current block
        }

        s.strstart += s.lookahead;
        s.lookahead = 0;

        // Emit a stored block if pending_buf will be full.
        const max_start: u64 = @as(u64, @intCast(s.block_start)) + max_block_size;
        if (s.strstart == 0 or @as(u64, s.strstart) >= max_start) {
            // strstart == 0 is possible when wrapping around on 16-bit
            // machines.
            s.lookahead = @intCast(@as(u64, s.strstart) - max_start);
            s.strstart = @intCast(max_start);
            if (s.flushBlock(false)) |bs| return bs;
        }
        // Flush if we may have to slide, otherwise block_start may become
        // negative and the data will be gone.
        if (s.strstart -% @as(u32, @intCast(s.block_start)) >= s.maxDist()) {
            if (s.flushBlock(false)) |bs| return bs;
        }
    }
    s.insert = 0;
    if (flush == Z_FINISH) {
        if (s.flushBlock(true)) |bs| return bs;
        return .finish_done;
    }
    if (@as(i64, s.strstart) > s.block_start) {
        if (s.flushBlock(false)) |bs| return bs;
    }
    return .block_done;
}
