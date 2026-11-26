# Zopfli native Zig integration — historical releases 1.0.0–1.0.3

The compressor is a fully native Zig implementation of the complete Zopfli
optimizer for **every official historical release** (1.0.0, 1.0.1, 1.0.2,
1.0.3). No external executable is spawned and no algorithmic C source is
compiled into the build.

## Release variants

`release.zig` defines the explicit `ZopfliRelease` variant, carried in the
options struct through the whole core (there is no mutable global switch):

| Functionality | Variant differences |
|---|---|
| `container.zig` | header bytes `78 01` (FLEVEL=0, 1.0.0/1.0.1) vs `78 da` (FLEVEL=3, 1.0.2+) |
| `deflate_tree_encode.zig` | `addDynamicTreeLegacy` reproduces 1.0.0's fixed-strategy tree encoder; 1.0.1+ use the 8-strategy search; `calculateTreeSize(.v1_0_0)` preserves upstream's byte-accounted size quirk |
| `deflate_dynamic.zig` | 1.0.0: raw histogram; 1.0.1: always `OptimizeHuffmanForRle`; 1.0.2+: try both, keep smaller (`tryOptimize`) |
| `deflate_block_size.zig` / `deflate_cost.zig` | btype-2 cost per variant; `calculateBlockSizeAutoType` only used by 1.0.2+ |
| `blocksplitter.zig` | 1.0.0/1.0.1 cost splits as dynamic-only blocks; 1.0.2+ use auto-type costs |
| `deflate_driver.zig` | 1.0.0/1.0.1: `DeflateSplittingFirst` + small-store fixed-tree recomparison, 20,000,000-byte master blocks, empty input emits nothing; 1.0.2+: merged-store double splitting, auto-type emission, 1,000,000-byte master blocks, fixed empty block |
| `squeeze_forward.zig` | legacy pruning expression (`costs[j+k] - costs[j] <= mincost`) for 1.0.0/1.0.1 |
| `native.zig` | empty input rejected for 1.0.0/1.0.1 (upstream CLI refuses empty files) |

1.0.2 and 1.0.3 share one code path (their only source difference is a
`malloc` cast); `profiles.zig` collapses the 1.0.2 profile into the 1.0.3
search representative and reports the group range `zopfli 1.0.2-1.0.3`.

| Component | Implementation | Status |
|---|---|---|
| RFC 1950 header, FLEVEL, checksum and trailer | `container.zig`, shared adler32 from the zlib-replicant engine | Native and active |
| Original Zopfli bit-output primitives | `bitstream.zig`, `deflate_tree_encode.zig` | Native and active |
| Rolling hash / match-chain primitives | `hash.zig` | Native, active through the original C ABI |
| Longest-match result caching and sublength encoding | `cache.zig` | Native, active through the original C ABI |
| LZ77 store lifecycle, token append, DEFLATE symbol mapping, cumulative histograms | `lz77_store.zig` | Native and active |
| Greedy and lazy LZ77 parse | `lz77_greedy.zig` | Native and active |
| Longest-match search, hash-chain switching, match-cache lookup/storage | `lz77_match.zig` | Native and active |
| Match-distance assertion / verification | `lz77_match.zig` | Native and active |
| Optimal path backtracking and token replay | `squeeze_path.zig` | Native and active |
| Squeeze symbol statistics, deterministic frequency perturbation and entropy | `squeeze_stats.zig` | Native and active |
| Fixed/dynamic LZ77 token cost models and minimum-cost probing | `squeeze_stats.zig` | Native and active |
| Forward dynamic-programming LZ77 optimization and long-repeat shortcut | `squeeze_forward.zig` | Native and active |
| Canonical Huffman symbol numbering and entropy | `tree.zig` | Native, active through the original C ABI |
| Length-limited Huffman bit lengths (bounded package-merge) | `katajainen.zig` | Native and active; upstream `katajainen.c` excluded, verified 4042/4042 byte-exact |
| Optimal LZ77 iterative and fixed-tree optimization | `squeeze_optimal.zig` | Native and active; upstream `squeeze.c` excluded |
| Block partitioning, split-point search, sorting and boundary conversion | `blocksplitter.zig` | Native and active; upstream `blocksplitter.c` excluded |
| Huffman frequency RLE optimization, fixed-tree lengths, distance-code compatibility patch | `deflate_rle.zig` | Native and active |
| Bit cost of LZ77 block symbols and automatic stored/fixed/dynamic cost selection | `deflate_cost.zig` | Native and active |
| Dynamic Huffman header RLE, eight coding strategies, tree-size calculation and bit output | `deflate_tree_encode.zig` | Native and active |
| Huffman emission of LZ77 literals, lengths, distances and extra bits | `deflate_lz77_output.zig` | Native and active |
| Dynamic Huffman code-length search and RLE accept/reject decision | `deflate_dynamic.zig` | Native and active |
| Stored/fixed/dynamic DEFLATE block-size model | `deflate_block_size.zig` | Native and active |
| Stored-block bytes, fixed/dynamic block serialization and automatic block choice | `deflate_blocks.zig` | Native and active |
| DEFLATE part/master-block control flow, both rounds of block splitting | `deflate_driver.zig` | Native and active; upstream `deflate.c` excluded |
| Historical release variants (1.0.0–1.0.3), options, container headers, master-block sizes | `release.zig` | Native and active |
| Release-aware verbose diagnostics (no C `stderr` dependency) | `verbose.zig` | Native and active |

The native entry point is `native.zig`: it constructs the upstream default
options (a faithful port of `util.c`'s `ZopfliInitOptions`), calls the Zig
DEFLATE driver directly and wraps the raw stream in the RFC 1950 container.
The transitional `bridge.c` and the last algorithmic C units (`katajainen.c`,
`util.c`) have been removed from the build entirely.
All public entry points from upstream `lz77.c` are now native Zig; that C
translation unit is excluded from the production build. The Zig store retains
power-of-two allocation growth and 288/32-symbol histogram boundaries. The
native match finder preserves the 8192-link chain limit, secondary hash and
longest-match cache. Conditional guards in the vendor reference are retained
for focused source-level comparisons.
The complete `squeeze.c` implementation has been moved to Zig, including
path reconstruction, statistic updates, deterministic RNG, both token cost
models, dynamic-programming forward pass and iterative optimization.
The upstream `squeeze.c` is preserved for reference but excluded from the
production build. The `float` cost table, callback order, strict comparisons,
long-repetition shortcut and frequency perturbation follow Zopfli 1.0.3.
The block splitter and DEFLATE block-cost estimator are fully in Zig.
The native encoder implements histogram smoothing for RLE, fixed Huffman
code lengths and the two-distance-code compatibility rule.
The block symbol cost model now runs in Zig for short and histogram-accelerated
large token ranges, as does `ZopfliCalculateBlockSizeAutoType`.
The dynamic Huffman-tree header encoder (`EncodeTree`), its eight RLE strategy
variants, size estimator and `AddDynamicTree` are now Zig implementations.
The LZ77 data-bit emitter (`AddLZ77Data`) also runs in Zig with the same
bit-level writer as the tree header. Dynamic code-length generation, the
RLE-optimized histogram comparison, and `ZopfliCalculateBlockSize` for all
three block types are native. `deflate_blocks.zig` serializes every block
type; `deflate_driver.zig` preserves both block-splitting rounds and the
1,000,000-byte master-block boundary. The upstream `deflate.c` remains in the
vendor reference but is no longer compiled into production.
The original upstream source distribution lives at
`binaries/vendor/zopfli-zopfli-1.0.3/`, retaining its Apache-2.0 `COPYING`
and copyright notices. New code is based on the source of version 1.0.3 and
the inter-release diffs of the official tags (see `EQUIVALENCE.md`).

## Verification

Build Zopfli 1.0.3 from the included source with `make zopfli` inside its
vendor directory, build the reference CLIs of 1.0.0–1.0.2 from the official
tagged tarballs, then run
`python3 scripts/diff_zopfli_native.py` (full streams for every release
variant, every match also decompresses back to the input) and
`python3 scripts/diff_katajainen.py`
(package-merge kernel against the original `katajainen.c`: empty and minimal
frequency sets, equal frequencies, skewed distributions, boundary cases at
`2^maxbits` symbols, limit reduction, random vectors and the 2^55 weight
rejection boundary).

The expanded byte-exact matrix was run after the full `deflate.c` migration
(empty, repeated, periodic, random and dictionary-reuse inputs; 1, 3, 5,
15 iterations). The search itself was also checked
against a Zopfli-generated stream with the external binary disabled.
This is a finite regression result, not a formal guarantee of every Zopfli
feature or cross-platform floating-point behavior.

The iteration search keeps a sparse default schedule. The opt-in
`--extended-zopfli` flag enables uncommon iteration counts in a later search
stage. In `zopfli-iterations-probe.json`, 6 deterministic fixtures compressed
with iterations 1–30 and 50 showed no additional byte-distinct output beyond
the standard schedule; this is useful evidence, not proof for arbitrary inputs.
