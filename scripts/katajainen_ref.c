/* Reference harness: feeds binary frequency vectors to the ORIGINAL
 * upstream Zopfli 1.0.3 katajainen.c and prints the resulting code lengths.
 * Wire format is shared with tools/zkatajainen.zig:
 *   stdin:  u32 LE n, u32 LE maxbits, n * u64 LE frequencies
 *   stdout: i32 LE rc, n * u32 LE bit lengths
 * Compile (see scripts/diff_katajainen.py):
 *   cc -O2 -I binaries/vendor/zopfli-zopfli-1.0.3/src/zopfli \
 *      scripts/katajainen_ref.c \
 *      binaries/vendor/zopfli-zopfli-1.0.3/src/zopfli/katajainen.c -o ref
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "katajainen.h"

int main(void) {
    uint32_t hdr[2];
    size_t n, i;
    uint32_t maxbits;
    size_t *freqs;
    unsigned *lens;
    int64_t *raw;
    int rc;

    if (fread(hdr, sizeof(uint32_t), 2, stdin) != 2) return 9;
    n = hdr[0];
    maxbits = hdr[1];
    freqs = calloc(n ? n : 1, sizeof(size_t));
    lens = calloc(n ? n : 1, sizeof(unsigned));
    raw = calloc(n ? n : 1, sizeof(int64_t));
    if (!freqs || !lens || !raw) return 9;
    if (n && fread(raw, sizeof(int64_t), n, stdin) != n) return 9;
    for (i = 0; i < n; i++) freqs[i] = (size_t)raw[i];

    rc = ZopfliLengthLimitedCodeLengths(freqs, (int)n, (int)maxbits, lens);

    fwrite(&rc, sizeof(int32_t), 1, stdout);
    for (i = 0; i < n; i++) {
        uint32_t v = lens[i];
        fwrite(&v, sizeof(uint32_t), 1, stdout);
    }
    return 0;
}
