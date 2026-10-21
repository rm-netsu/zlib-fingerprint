//! deflate_stored — the zlib 1.2.9 variant (level 0).
//!
//! First rewrite of the stored path: blocks are copied directly to the
//! output whenever they are at least `min_block` long, sized by avail_out.
//!
//! Known divergence from 1.2.10+ (confirmed empirically): for EMPTY input
//! with Z_FINISH this version returns finish_done without emitting any
//! deflate block at all — the output stream is just the zlib header plus
//! the adler32 trailer. 1.2.10 fixed that by always emitting the final
//! empty stored block (see `stored.zig`).

const std = @import("std");
const st = @import("state.zig");
const trees = @import("trees.zig");

const DeflateState = st.DeflateState;
const BlockState = st.BlockState;
const MAX_STORED = st.MAX_STORED;
const Z_NO_FLUSH = st.Z_NO_FLUSH;
const Z_FINISH = st.Z_FINISH;

pub fn deflateStored129(s: *DeflateState, flush: u32) BlockState {
    // Smallest worthy block size when not flushing or finishing. By default
    // this is 32K. This can be as small as 507 bytes for memLevel == 1.
    const min_block = @min(s.pending_buf_size - 5, s.w_size);

    var last: u32 = 0;
    const used_in = s.avail_in;
    while (true) {
        // Set len to the maximum size block that we can copy directly with
        // the available input data and output space. Set left to how much of
        // that would be copied from what's left in the window.
        var len: u64 = MAX_STORED; // maximum deflate stored block length
        var have: u32 = @intCast(@as(u32, @intCast(s.bi_valid + 42)) >> 3); // header bytes
        // maximum stored block length that will fit in avail_out:
        have = if (s.avail_out > have) s.avail_out - have else 0;
        var left: u64 = @as(u64, s.strstart) -% @as(u64, @bitCast(s.block_start)); // bytes left in window
        if (len > left + s.avail_in) len = left + s.avail_in; // limit len to the input
        if (len > have) len = have; // limit len to the output
        if (left > len) left = len; // limit window pull to len

        // If the stored block would be less than min_block in length, or if
        // unable to copy all of the available input when flushing, then try
        // copying to the window and the pending buffer instead.
        if (len < min_block and (len == 0 or flush == Z_NO_FLUSH or
            len - left != s.avail_in))
        {
            break;
        }

        // Make a dummy stored block in pending to get the header bytes,
        // including any pending bits.
        last = if (flush == Z_FINISH and len - left == s.avail_in) 1 else 0;
        trStoredBlockDummy(s, last);

        // Replace the lengths in the dummy stored block with len.
        const len16: u16 = @truncate(len);
        const nlen: u16 = ~len16;
        s.pending_buf[s.pending - 4] = @truncate(len);
        s.pending_buf[s.pending - 3] = @truncate(len >> 8);
        s.pending_buf[s.pending - 2] = @truncate(nlen);
        s.pending_buf[s.pending - 1] = @truncate(nlen >> 8);

        // Write the stored block header bytes.
        s.flushPending();

        // Copy uncompressed bytes from the window to next_out.
        if (left != 0) {
            const l: usize = @intCast(left);
            @memcpy(s.output[s.next_out .. s.next_out + l], s.window[@intCast(s.block_start)..][0..l]);
            s.next_out += l;
            s.avail_out -= @intCast(l);
            s.block_start += @intCast(l);
            len -= left;
        }

        // Copy uncompressed bytes directly from next_in to next_out.
        if (len != 0) {
            const l: usize = @intCast(len);
            _ = s.readBuf(s.output[s.next_out .. s.next_out + l]);
            s.next_out += l;
            s.avail_out -= @intCast(l);
        }
    }

    // Update the sliding window with the last s->w_size bytes of the copied
    // data, or append all of the copied data to the existing window if less
    // than s->w_size bytes were copied.
    const used = used_in - s.avail_in; // number of input bytes directly copied
    if (used != 0) {
        if (used >= s.w_size) { // supplant the previous history
            s.matches = 2; // clear hash
            @memcpy(s.window[0..s.w_size], s.input[s.next_in - s.w_size .. s.next_in]);
            s.strstart = s.w_size;
        } else {
            if (s.window_size - @as(u64, s.strstart) <= used) {
                // Slide the window down.
                s.strstart -= s.w_size;
                std.mem.copyForwards(u8, s.window[0..s.strstart], s.window[s.w_size .. s.w_size + s.strstart]);
                if (s.matches < 2) s.matches += 1; // add a pending slide_hash()
            }
            @memcpy(s.window[s.strstart .. s.strstart + used], s.input[s.next_in - used .. s.next_in]);
            s.strstart += used;
        }
        s.block_start = s.strstart;
        s.insert += @min(used, s.w_size - s.insert);
    }

    // If flushing or finishing and all input has been consumed, then done.
    // If the code above couldn't write a complete block to next_out, then
    // the code following this won't be able to either.
    if (flush != Z_NO_FLUSH and s.avail_in == 0 and @as(i64, s.strstart) == s.block_start) {
        return if (flush == Z_FINISH) .finish_done else .block_done;
    }

    // Fill the window with any remaining input.
    var have2: u64 = s.window_size - s.strstart - 1;
    if (s.avail_in > have2 and s.block_start >= @as(i64, @intCast(s.w_size))) {
        // Slide the window down.
        s.block_start -= s.w_size;
        s.strstart -= s.w_size;
        std.mem.copyForwards(u8, s.window[0..s.strstart], s.window[s.w_size .. s.w_size + s.strstart]);
        if (s.matches < 2) s.matches += 1; // add a pending slide_hash()
        have2 += s.w_size; // more space now
    }
    if (have2 > s.avail_in) have2 = s.avail_in;
    if (have2 != 0) {
        _ = s.readBuf(s.window[@intCast(s.strstart)..@intCast(s.strstart + have2)]);
        s.strstart += @intCast(have2);
    }

    // There was not enough avail_out to write a complete worthy or flushed
    // stored block to next_out. Write a stored block to pending instead, if
    // we have enough input for a worthy block, or if flushing and there is
    // enough room for the remaining input as a stored block in the pending
    // buffer.
    var have3: u32 = @intCast(@as(u32, @intCast(s.bi_valid + 42)) >> 3); // header bytes
    // maximum stored block length that will fit in pending:
    have3 = @min(s.pending_buf_size - have3, @as(u32, MAX_STORED));
    const min_block3 = @min(have3, s.w_size);
    const left3: u64 = @as(u64, s.strstart) -% @as(u64, @bitCast(s.block_start));
    if (left3 >= min_block3 or
        ((left3 != 0 or flush == Z_FINISH) and flush != Z_NO_FLUSH and
            s.avail_in == 0 and left3 <= @as(u64, have3)))
    {
        const len3: u32 = @intCast(@min(left3, @as(u64, have3)));
        const last3: bool = flush == Z_FINISH and s.avail_in == 0 and len3 == left3;
        trStoredBlockFromWindow(s, len3, last3);
        s.block_start += len3;
        s.flushPending();
        if (last3) return .finish_started;
    }

    // We've done all we can with the available input and output.
    return .need_more;
}

/// _tr_stored_block with a NULL buffer (dummy header only).
inline fn trStoredBlockDummy(s: *DeflateState, last: u32) void {
    trees.trStoredBlock(s, null, 0, last != 0);
}

/// _tr_stored_block reading from the window.
inline fn trStoredBlockFromWindow(s: *DeflateState, len: u32, last: bool) void {
    const buf: []const u8 = s.window[@intCast(s.block_start)..][0..len];
    trees.trStoredBlock(s, buf, len, last);
}
