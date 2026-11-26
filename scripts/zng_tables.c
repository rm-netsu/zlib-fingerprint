/* Extract zlib-ng 2.2.1 static tables as Zig array literals (byte-exact),
 * for the generation of src/zlibng/tables.zig.
 * Compile against the vendored sources (see binaries/build-binaries.sh) and
 * run: gcc -O1 <this file> -o /tmp/tables && /tmp/tables > tables.zig */
/* Extract zlib-ng's static tables as Zig literals (byte-exact). */
#include <stdio.h>
#include <stdint.h>
#include "/home/z/my-project/work/binaries/vendor/zlib-ng-2.2.1/zbuild.h"
#include "/home/z/my-project/work/binaries/vendor/zlib-ng-2.2.1/zutil.h"
#include "/home/z/my-project/work/binaries/vendor/zlib-ng-2.2.1/deflate.h"
#include "/home/z/my-project/work/binaries/vendor/zlib-ng-2.2.1/trees.h"
#include "/home/z/my-project/work/binaries/vendor/zlib-ng-2.2.1/trees_tbl.h"

int main(void) {
    printf("/// static_ltree: (code, len) pairs, L_CODES+2 = 288 entries.\n");
    printf("pub const static_ltree = [288]CtData{\n");
    for (int i = 0; i < 288; i++)
        printf("    .{ .code = %u, .len = %u },\n", static_ltree[i].fc.code, static_ltree[i].dl.len);
    printf("};\n\n");

    printf("pub const static_dtree = [30]CtData{\n");
    for (int i = 0; i < 30; i++)
        printf("    .{ .code = %u, .len = %u },\n", static_dtree[i].fc.code, static_dtree[i].dl.len);
    printf("};\n\n");

    printf("pub const dist_code = [512]u8{\n");
    for (int i = 0; i < 512; i++) {
        printf("%d,", zng_dist_code[i]);
        if ((i+1) % 32 == 0) printf("\n");
    }
    printf("};\n\n");

    printf("pub const length_code = [256]u8{\n");
    for (int i = 0; i < 256; i++) {
        printf("%d,", zng_length_code[i]);
        if ((i+1) % 32 == 0) printf("\n");
    }
    printf("};\n\n");

    printf("pub const base_length = [29]u16{\n");
    for (int i = 0; i < 29; i++) printf("%d,", base_length[i]);
    printf("\n};\n\n");

    printf("pub const base_dist = [30]u16{\n");
    for (int i = 0; i < 30; i++) printf("%d,", base_dist[i]);
    printf("\n};\n\n");

    printf("pub const extra_lbits = [29]u8{\n");
    for (int i = 0; i < 29; i++) printf("%d,", extra_lbits[i]);
    printf("\n};\n\n");

    printf("pub const extra_dbits = [30]u8{\n");
    for (int i = 0; i < 30; i++) printf("%d,", extra_dbits[i]);
    printf("\n};\n\n");

    printf("pub const extra_blbits = [19]u8{\n");
    for (int i = 0; i < 19; i++) printf("%d,", extra_blbits[i]);
    printf("\n};\n\n");

    printf("pub const bl_order = [19]u8{\n");
    for (int i = 0; i < 19; i++) printf("%d,", bl_order[i]);
    printf("\n};\n");
    return 0;
}
