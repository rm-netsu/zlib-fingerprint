#include <stdio.h>
#include <stdlib.h>
#include <zlib.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#define CHUNK 16384

int main(int argc, char *argv[]) {
    #ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    #endif

    int level = Z_DEFAULT_COMPRESSION;
    int memLevel = 8;
    int strategy = Z_DEFAULT_STRATEGY;

    if (argc > 1) level = atoi(argv[1]);
    if (argc > 2) memLevel = atoi(argv[2]);
    if (argc > 3) strategy = atoi(argv[3]);

    z_stream strm;
    strm.zalloc = Z_NULL;
    strm.zfree = Z_NULL;
    strm.opaque = Z_NULL;

    // Инициализация с учетом особенностей zlib-ng compat API
    if (deflateInit2(&strm, level, Z_DEFLATED, 15, memLevel, strategy) != Z_OK) {
        return 1;
    }

    unsigned char in[CHUNK];
    unsigned char out[CHUNK];
    int flush;

    do {
        strm.avail_in = fread(in, 1, CHUNK, stdin);
        if (ferror(stdin)) {
            deflateEnd(&strm);
            return 2;
        }
        flush = feof(stdin) ? Z_FINISH : Z_NO_FLUSH;
        strm.next_in = in;

        do {
            strm.avail_out = CHUNK;
            strm.next_out = out;
            deflate(&strm, flush);
            unsigned int have = CHUNK - strm.avail_out;
            if (fwrite(out, 1, have, stdout) != have || ferror(stdout)) {
                deflateEnd(&strm);
                return 3;
            }
        } while (strm.avail_out == 0);
    } while (flush != Z_FINISH);

    deflateEnd(&strm);
    return 0;
}
