#include <stdio.h>
#include <stdlib.h>
#include "libdeflate.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#define CHUNK (2 * 1024 * 1024) // 2 МБ под размер uncompressed IDAT потока

int main(int argc, char *argv[]) {
    #ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    #endif

    int level = 4; // Уровень по умолчанию в libdeflate
    if (argc > 1) level = atoi(argv[1]);

    // Читаем весь stdin в память
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

    struct libdeflate_compressor *compressor = libdeflate_alloc_compressor(level);
    if (!compressor) {
        free(in_buf);
        return 2;
    }

    size_t max_out_size = libdeflate_zlib_compress_bound(compressor, size);
    unsigned char *out_buf = malloc(max_out_size);
    if (!out_buf) {
        libdeflate_free_compressor(compressor);
        free(in_buf);
        return 3;
    }

    size_t compressed_size = libdeflate_zlib_compress(compressor, in_buf, size, out_buf, max_out_size);
    if (compressed_size == 0) {
        free(out_buf);
        libdeflate_free_compressor(compressor);
        free(in_buf);
        return 4;
    }

    fwrite(out_buf, 1, compressed_size, stdout);

    free(out_buf);
    libdeflate_free_compressor(compressor);
    free(in_buf);
    return 0;
}
