/* zstream_wrapper.c — scenario-driven *streaming* compressor around a specific
 * zlib build.
 *
 * Unlike zlib_wrapper.c (whole input, single Z_FINISH), this wrapper exercises
 * the streaming API: chunked input, flush operations at byte offsets or after
 * every chunk, capped avail_out per call, mid-stream deflateParams,
 * deflateSetDictionary, deflateReset and deflateCopy.
 *
 * All scenarios read the payload from stdin, write the produced stream to
 * stdout and print a one-line JSON status object to stderr:
 *   {"mode":"...","ret":<last deflate return>,"calls":<deflate calls>,...}
 *
 * Usage:
 *   zstream one    <lvl> <mem> <strat> <wbits> <inchunk> <outchunk>
 *   zstream oneshot <lvl> <mem> <strat> <wbits> <ignored> <outchunk>
 *   zstream marks  <lvl> <mem> <strat> <wbits> <inchunk> <outchunk> <flush> <off1> [off2 ...]
 *   zstream every  <lvl> <mem> <strat> <wbits> <inchunk> <outchunk> <flush>
 *   zstream params <lvl> <mem> <strat> <wbits> <inchunk> <outchunk> <off> <lvl2> <strat2>
 *   zstream dict   <lvl> <mem> <strat> <wbits> <inchunk> <outchunk> <dictlen>
 *   zstream reset  <lvl> <mem> <strat> <wbits> <inchunk> <outchunk>
 *   zstream copy   <lvl> <mem> <strat> <wbits> <inchunk> <outchunk> <off>
 *   zstream copy2  <lvl> <mem> <strat> <wbits> <inchunk> <outchunk> <off>
 *
 * inchunk  — max avail_in bytes fed per deflate() batch (0 = whole input).
 * outchunk — max avail_out per deflate() call (0 = unrestricted room).
 * marks: a flush of the given numeric type is issued once the byte offset is
 * reached (offsets ascending). every: the flush is issued after every chunk.
 * dict: dictionary = first <dictlen> payload bytes, whole payload compressed.
 * reset: payload compressed, deflateReset, compressed again; only the second
 * stream is written. copy: deflateCopy at <off>, source stream finished.
 * copy2: deflateCopy at <off>, only the clone's continuation is finished.
 *
 * Exit codes: 0 ok (Z_STREAM_END); 2 init; 3 alloc; 4 no Z_STREAM_END;
 * 5 write; 6 deflateParams; 7 dictionary; 8 deflateCopy; 9 deflateReset;
 * 10 flush-stage error; 11 feed-stage error.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdint.h>
#include <zlib.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

typedef struct {
    unsigned char *buf;
    size_t cap;
    size_t have;
    size_t out_chunk; /* 0 = unrestricted */
    long calls;
} sink;

static void status_json(const char *mode, int ret, long calls, int aux) {
    fprintf(stderr, "{\"mode\":\"%s\",\"ret\":%d,\"calls\":%ld,\"aux\":%d}\n",
            mode, ret, calls, aux);
}

/* One deflate() call batch with the flush argument; keeps pumping while the
 * output room is exhausted. Returns the last deflate() return code. */
static int pump(z_stream *s, sink *k, int flush) {
    int ret = Z_OK;
    for (;;) {
        if (k->have == k->cap) return Z_BUF_ERROR;
        size_t room = k->cap - k->have;
        if (k->out_chunk && k->out_chunk < room) room = k->out_chunk;
        s->next_out = k->buf + k->have;
        s->avail_out = (uInt)room;
        ret = deflate(s, flush);
        k->calls++;
        k->have += room - s->avail_out;
        if (ret != Z_OK) return ret;
        if (s->avail_out != 0) return ret;
    }
}

/* Feed data[0..len) in inchunk pieces, no flush. */
static int feed(z_stream *s, sink *k, const unsigned char *data, size_t len,
                size_t inchunk) {
    size_t off = 0;
    while (off < len) {
        size_t n = inchunk && inchunk < len - off ? inchunk : len - off;
        s->next_in = (unsigned char *)(data + off);
        s->avail_in = (uInt)n;
        int ret = pump(s, k, Z_NO_FLUSH);
        while (ret == Z_OK && s->avail_in != 0) ret = pump(s, k, Z_NO_FLUSH);
        if (ret != Z_OK) return ret;
        off += n;
    }
    return Z_OK;
}

static int read_all(unsigned char **out, size_t *out_len) {
    size_t cap = 1 << 20, size = 0;
    unsigned char *buf = malloc(cap);
    if (!buf) return 0;
    for (;;) {
        if (size == cap) {
            cap *= 2;
            unsigned char *nb = realloc(buf, cap);
            if (!nb) { free(buf); return 0; }
            buf = nb;
        }
        size_t n = fread(buf + size, 1, cap - size, stdin);
        size += n;
        if (n == 0) break;
    }
    *out = buf;
    *out_len = size;
    return 1;
}

static int write_all(const unsigned char *buf, size_t len) {
    return len == 0 || fwrite(buf, 1, len, stdout) == len;
}

int main(int argc, char *argv[]) {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    if (argc < 8) {
        fprintf(stderr, "usage: zstream <mode> <lvl> <mem> <strat> <wbits> <inchunk> <outchunk> [...]\n");
        return 2;
    }
    const char *mode = argv[1];
    int level = atoi(argv[2]);
    int memLevel = atoi(argv[3]);
    int strategy = atoi(argv[4]);
    int windowBits = atoi(argv[5]);
    size_t inchunk = (size_t)strtoul(argv[6], NULL, 10);
    size_t outchunk = (size_t)strtoul(argv[7], NULL, 10);

    unsigned char *data;
    size_t size;
    if (!read_all(&data, &size)) return 3;
    if (size > UINT_MAX || size > (SIZE_MAX - 65536) / 2) { free(data); return 3; }

    size_t extra = 0;
    if (inchunk) extra = (size / inchunk + 4) * 16 + 65536;
    size_t cap = size * 2 + 65536 + extra + 65536;
    sink k;
    k.buf = malloc(cap);
    k.cap = cap;
    k.have = 0;
    k.out_chunk = outchunk;
    k.calls = 0;
    if (!k.buf) { free(data); return 3; }

    z_stream strm;
    strm.zalloc = Z_NULL;
    strm.zfree = Z_NULL;
    strm.opaque = Z_NULL;
    strm.next_in = Z_NULL;
    strm.avail_in = 0;
    if (deflateInit2(&strm, level, Z_DEFLATED, windowBits, memLevel, strategy) != Z_OK) {
        status_json(mode, -1, 0, 0);
        free(k.buf); free(data);
        return 2;
    }

    int exit_code = 0;
    int final_ret = Z_OK;
    int aux = 0;

    if (strcmp(mode, "one") == 0 || strcmp(mode, "reset") == 0
        || strcmp(mode, "oneshot") == 0) {
        if (strcmp(mode, "oneshot") == 0) {
            /* Single-Z_FINISH producer model (identical to zlib_wrapper.c):
             * all input presented at once, repeated Z_FINISH calls only as
             * the avail_out cap forces them. inchunk is ignored. */
            k.have = 0;
            strm.next_in = data;
            strm.avail_in = (uInt)size;
            final_ret = pump(&strm, &k, Z_FINISH);
            if (final_ret != Z_STREAM_END) exit_code = 4;
        } else {
        int rounds = strcmp(mode, "reset") == 0 ? 2 : 1;
        for (int round = 0; round < rounds; round++) {
            k.have = 0; /* reset mode: keep only the post-reset stream */
            final_ret = feed(&strm, &k, data, size, inchunk);
            if (final_ret != Z_OK) { exit_code = 11; break; }
            final_ret = pump(&strm, &k, Z_FINISH);
            if (final_ret != Z_STREAM_END) { exit_code = 4; break; }
            if (round + 1 < rounds) {
                if (deflateReset(&strm) != Z_OK) {
                    status_json(mode, -2, k.calls, aux);
                    deflateEnd(&strm); free(k.buf); free(data);
                    return 9;
                }
            }
        }
        }
    } else if (strcmp(mode, "marks") == 0 && argc >= 9) {
        int flush = atoi(argv[8]);
        size_t prev = 0;
        final_ret = Z_OK;
        for (int i = 9; i < argc; i++) {
            size_t off = (size_t)strtoul(argv[i], NULL, 10);
            if (off > size) off = size;
            if (off < prev) off = prev;
            final_ret = feed(&strm, &k, data + prev, off - prev, inchunk);
            if (final_ret != Z_OK) { exit_code = 11; break; }
            final_ret = pump(&strm, &k, flush);
            if (final_ret != Z_OK) { exit_code = 10; aux = 1; break; }
            prev = off;
        }
        if (exit_code == 0) {
            final_ret = feed(&strm, &k, data + prev, size - prev, inchunk);
            if (final_ret != Z_OK) exit_code = 11;
        }
        if (exit_code == 0) {
            final_ret = pump(&strm, &k, Z_FINISH);
            if (final_ret != Z_STREAM_END) exit_code = 4;
        }
    } else if (strcmp(mode, "every") == 0 && argc >= 9) {
        int flush = atoi(argv[8]);
        size_t off = 0;
        final_ret = Z_OK;
        while (off < size) {
            size_t n = inchunk && inchunk < size - off ? inchunk : size - off;
            final_ret = feed(&strm, &k, data + off, n, 0);
            if (final_ret != Z_OK) { exit_code = 11; break; }
            final_ret = pump(&strm, &k, flush);
            if (final_ret != Z_OK) { exit_code = 10; aux = 1; break; }
            off += n;
        }
        if (exit_code == 0) {
            final_ret = pump(&strm, &k, Z_FINISH);
            if (final_ret != Z_STREAM_END) exit_code = 4;
        }
    } else if (strcmp(mode, "params") == 0 && argc >= 11) {
        size_t off = (size_t)strtoul(argv[8], NULL, 10);
        if (off > size) off = size;
        int level2 = atoi(argv[9]);
        int strat2 = atoi(argv[10]);
        final_ret = feed(&strm, &k, data, off, inchunk);
        if (final_ret != Z_OK) exit_code = 11;
        if (exit_code == 0) {
            /* deflateParams() writes pending output through next_out/avail_out;
             * give it the whole remaining room regardless of outchunk. */
            strm.next_out = k.buf + k.have;
            strm.avail_out = (uInt)(k.cap - k.have);
            int pr = deflateParams(&strm, level2, strat2);
            k.calls++;
            k.have = k.cap - strm.avail_out;
            aux = pr;
            if (pr != Z_OK) exit_code = 6;
        }
        if (exit_code == 0) {
            final_ret = feed(&strm, &k, data + off, size - off, inchunk);
            if (final_ret != Z_OK) exit_code = 11;
        }
        if (exit_code == 0) {
            final_ret = pump(&strm, &k, Z_FINISH);
            if (final_ret != Z_STREAM_END) exit_code = 4;
        }
    } else if (strcmp(mode, "dict") == 0 && argc >= 9) {
        size_t dictlen = (size_t)strtoul(argv[8], NULL, 10);
        if (dictlen > size) dictlen = size;
        int dr = deflateSetDictionary(&strm, data, (uInt)dictlen);
        aux = dr;
        if (dr != Z_OK) exit_code = 7;
        if (exit_code == 0) {
            final_ret = feed(&strm, &k, data, size, inchunk);
            if (final_ret != Z_OK) exit_code = 11;
        }
        if (exit_code == 0) {
            final_ret = pump(&strm, &k, Z_FINISH);
            if (final_ret != Z_STREAM_END) exit_code = 4;
        }
    } else if ((strcmp(mode, "copy") == 0 || strcmp(mode, "copy2") == 0)
               && argc >= 9) {
        size_t off = (size_t)strtoul(argv[8], NULL, 10);
        if (off > size) off = size;
        final_ret = feed(&strm, &k, data, off, inchunk);
        if (final_ret != Z_OK) exit_code = 11;
        z_stream clone;
        clone.zalloc = Z_NULL;
        clone.zfree = Z_NULL;
        clone.opaque = Z_NULL;
        if (exit_code == 0) {
            if (deflateCopy(&clone, &strm) != Z_OK) {
                status_json(mode, -3, k.calls, aux);
                deflateEnd(&strm); free(k.buf); free(data);
                return 8;
            }
        }
        if (exit_code == 0 && strcmp(mode, "copy") == 0) {
            final_ret = feed(&strm, &k, data + off, size - off, inchunk);
            if (final_ret != Z_OK) exit_code = 11;
            if (exit_code == 0) {
                final_ret = pump(&strm, &k, Z_FINISH);
                if (final_ret != Z_STREAM_END) exit_code = 4;
            }
        } else if (exit_code == 0) { /* copy2: finish the clone instead */
            final_ret = feed(&clone, &k, data + off, size - off, inchunk);
            if (final_ret != Z_OK) exit_code = 11;
            if (exit_code == 0) {
                final_ret = pump(&clone, &k, Z_FINISH);
                if (final_ret != Z_STREAM_END) exit_code = 4;
            }
        }
        deflateEnd(&clone);
    } else {
        status_json(mode, -9, 0, 0);
        deflateEnd(&strm); free(k.buf); free(data);
        return 2;
    }

    status_json(mode, final_ret, k.calls, aux);
    if (exit_code == 0 && !write_all(k.buf, k.have)) exit_code = 5;
    deflateEnd(&strm);
    free(k.buf);
    free(data);
    return exit_code;
}
