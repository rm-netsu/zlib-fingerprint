#include <stdio.h>
#include <stdlib.h>
#include "miniz.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#define CHUNK (2 * 1024 * 1024)

int main(int argc, char *argv[]) {
    #ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    #endif

    int level = MZ_DEFAULT_COMPRESSION;
    if (argc > 1) level = atoi(argv[1]);

    // Читаем весь входной поток из stdin в память
    size_t capacity = CHUNK;
    size_t size = 0;
    unsigned char *in_buf = malloc(capacity);
    if (!in_buf) return 1;

    size_t n;
    while ((n = fread(in_buf + size, 1, capacity - size, stdin)) > 0) {
        size += n;
        if (size == capacity) {
            capacity *= 2;
            unsigned char *new_buf = realloc(in_buf, capacity);
            if (!new_buf) {
                free(in_buf);
                return 1;
            }
            in_buf = new_buf;
        }
    }

    // miniz функция упаковки в zlib формат
    mz_ulong max_out_size = compressBound(size) + 64;
    unsigned char *out_buf = malloc(max_out_size);
    if (!out_buf) {
        free(in_buf);
        return 2;
    }

    mz_ulong compressed_size = max_out_size;
    // tdefl/miniz zlib-компрессия
    int status = mz_compress2(out_buf, &compressed_size, in_buf, size, level);
    if (status != MZ_OK) {
        free(out_buf);
        free(in_buf);
        return 3;
    }

    fwrite(out_buf, 1, compressed_size, stdout);

    free(out_buf);
    free(in_buf);
    return 0;
}
