/* The same adapter is compiled four times against four genuine historical
 * zlib source trees. ZF_ENTRY and every exported zlib symbol are renamed by
 * build.zig, so all generations can coexist in one executable.
 *
 * All input is supplied before Z_FINISH; one sufficiently large output buffer
 * keeps the one-shot producer semantics used by the reference wrappers.
 */
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "zlib.h"

#ifndef ZF_ENTRY
#error "ZF_ENTRY must be specified by build.zig"
#endif

int ZF_ENTRY(const unsigned char *input, size_t input_len,
             unsigned char *output, size_t output_capacity,
             size_t *written, int level, int mem_level,
             int strategy, int window_bits) {
    if (input_len > UINT_MAX || input_len > (SIZE_MAX - 65536) / 2)
        return -1;
    size_t capacity = input_len * 2 + 65536;
    if (capacity > UINT_MAX) return -1;
    unsigned char *temporary = malloc(capacity);
    if (!temporary) return -1;

    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    int rc = deflateInit2(&stream, level, Z_DEFLATED, window_bits,
                          mem_level, strategy);
    if (rc != Z_OK) {
        free(temporary);
        return rc;
    }
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_len;
    stream.next_out = temporary;
    stream.avail_out = (uInt)capacity;
    rc = deflate(&stream, Z_FINISH);
    if (rc == Z_STREAM_END) {
        size_t size = capacity - stream.avail_out;
        if (size <= output_capacity) {
            memcpy(output, temporary, size);
            *written = size;
        } else rc = Z_BUF_ERROR;
    }
    deflateEnd(&stream);
    free(temporary);
    return rc == Z_STREAM_END ? 0 : rc;
}
