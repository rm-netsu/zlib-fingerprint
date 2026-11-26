/* Extract miniz 3.1.2 static tables as Zig array literals (byte-exact),
 * for the generation of src/miniz/tables.zig.
 * Compile against the vendored sources (see binaries/build-binaries.sh) and
 * run: gcc -O1 <this file> -o /tmp/tables && /tmp/tables > tables.zig */
/* Extract miniz's static tdefl tables as Zig array literals, byte-exact,
 * by compiling miniz.c into this translation unit (file-static tables
 * become visible). */
#include <stdio.h>

/* Neutralize parts of miniz.c we do not need. */
#define MINIZ_NO_ARCHIVE_APIS 1
#define MINIZ_NO_ARCHIVE_WRITING_APIS 1
#define MINIZ_NO_ARCHIVE_READING_APIS 1
#define MINIZ_NO_TIME 1

#include "/home/z/my-project/work/binaries/vendor/miniz-3.1.2/miniz.c"

static void print_u8(const char *name, const mz_uint8 *tab, int n) {
    printf("pub const %s = [%d]u8{\n", name, n);
    for (int i = 0; i < n; i++) {
        printf("%d,%s", tab[i], ((i + 1) % 32) ? "" : "\n");
    }
    printf("};\n\n");
}

int main(void) {
    printf("pub const len_sym = [256]u16{\n");
    for (int i = 0; i < 256; i++) {
        printf("%d,%s", s_tdefl_len_sym[i], ((i + 1) % 32) ? "" : "\n");
    }
    printf("};\n\n");
    print_u8("len_extra", s_tdefl_len_extra, 256);
    print_u8("small_dist_sym", s_tdefl_small_dist_sym, 512);
    print_u8("small_dist_extra", s_tdefl_small_dist_extra, 512);
    print_u8("large_dist_sym", s_tdefl_large_dist_sym, 128);
    print_u8("large_dist_extra", s_tdefl_large_dist_extra, 128);
    print_u8("packed_code_size_syms_swizzle", s_tdefl_packed_code_size_syms_swizzle, 19);
    return 0;
}
