/* zlib_wrapper.c — stdin-to-stdout compressor around a specific zlib build.
 *
 * The whole input is read first and then deflated with a single Z_FINISH
 * call, mirroring the one-shot compression pattern used by the most common
 * producers (python zlib.compress, node zlib.deflateSync, ...). Block
 * layout matters for bit-exact reproduction: for level 0 (deflate_stored)
 * the block splitting depends on the flush pattern, so the wrapper must
 * not stream the input through in chunks.
 *
 * Usage: zlib_wrapper [level] [memLevel] [strategy] [windowBits]
 * Both the wrapper and the linked libz.a define the fingerprinted version.
 */
#include <stdio.h>
#include <stdlib.h>
#include <zlib.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

int main(int argc, char *argv[]) {
    #ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    #endif

    int level = Z_DEFAULT_COMPRESSION;
    int memLevel = 8;
    int strategy = Z_DEFAULT_STRATEGY;
    int windowBits = 15;

    if (argc > 1) level = atoi(argv[1]);
    if (argc > 2) memLevel = atoi(argv[2]);
    if (argc > 3) strategy = atoi(argv[3]);
    if (argc > 4) windowBits = atoi(argv[4]);

    /* Read the whole input. */
    size_t capacity = 1 << 20;
    size_t size = 0;
    unsigned char *in_buf = malloc(capacity);
    if (!in_buf) return 1;
    for (;;) {
        if (size == capacity) {
            capacity *= 2;
            unsigned char *nb = realloc(in_buf, capacity);
            if (!nb) { free(in_buf); return 1; }
            in_buf = nb;
        }
        size_t n = fread(in_buf + size, 1, capacity - size, stdin);
        size += n;
        if (n == 0) break;
    }

    z_stream strm;
    strm.zalloc = Z_NULL;
    strm.zfree = Z_NULL;
    strm.opaque = Z_NULL;

    if (deflateInit2(&strm, level, Z_DEFLATED, windowBits, memLevel, strategy) != Z_OK) {
        free(in_buf);
        return 2;
    }

    size_t out_capacity = deflateBound(&strm, (uLong)size) + 64;
    unsigned char *out_buf = malloc(out_capacity);
    if (!out_buf) {
        deflateEnd(&strm);
        free(in_buf);
        return 3;
    }

    strm.next_in = in_buf;
    strm.avail_in = (uInt)size;
    strm.next_out = out_buf;
    strm.avail_out = (uInt)out_capacity;

    int ret = deflate(&strm, Z_FINISH);
    if (ret != Z_STREAM_END) {
        deflateEnd(&strm);
        free(out_buf);
        free(in_buf);
        return 4;
    }

    size_t have = out_capacity - strm.avail_out;
    if (fwrite(out_buf, 1, have, stdout) != have) {
        deflateEnd(&strm);
        free(out_buf);
        free(in_buf);
        return 5;
    }

    deflateEnd(&strm);
    free(out_buf);
    free(in_buf);
    return 0;
}
