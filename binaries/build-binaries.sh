#!/usr/bin/env bash
# Build all compressor binaries used by the zlib-fingerprint search engine.
# Vendor sources are kept under vendor/ for reference (header-writing logic,
# version diffing) and are NOT deleted after the build.
set -e

CDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$CDIR/vendor"
cd "$CDIR"

echo "=== Preparing binaries in directory: $CDIR ==="

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    EXT=".exe"
else
    EXT=""
fi

check_binary() {
    local name="$1"
    local bin_file="$name$EXT"
    if [ -f "$bin_file" ]; then
        echo "-> [SKIP] $bin_file already exists."
        return 0
    fi
    return 1
}

mkdir -p "$VENDOR"

fetch() { # fetch <url> <dest-file> (atomic: partial downloads never persist)
    if [ -f "$2" ]; then
        return 0
    fi
    echo "   downloading $(basename "$2")..."
    curl -fsSL --retry 2 --max-time 180 -o "$2.part" "$1" && mv "$2.part" "$2" || {
        rm -f "$2.part" "$2"
        return 1
    }
}

# Resolve the in-repo copy of an engine package. Preference order:
#   1. an engine-repository clone at <clone-name>/ (the layout the
#      differential suites and the README use — see the CI workflow);
#   2. the fetched dependency cache under zig-pkg/ (populated by
#      'zig build'; the directory name embeds the version and hash, so
#      it must be discovered, never hardcoded — it changes on every
#      package bump).
pkg_dir() { # pkg_dir <cache-prefix> <clone-name>
    local found
    if [ -d "$CDIR/../$2" ]; then
        printf '%s\n' "$CDIR/../$2"
        return 0
    fi
    found="$(cd "$CDIR/.." && ls -1d zig-pkg/"$1"-*/ 2>/dev/null | sort -V | tail -n 1)" || true
    if [ -n "$found" ]; then
        printf '%s\n' "$CDIR/../${found%/}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# zlib family (official versions) — the differential-testing oracles of the
# zlib-replicant engine package. The wrapper sources and the build recipe
# live IN the package (zlib-replicant/binaries); this script delegates so
# one shared set of reference wrappers (zlib-<ver>, zstream-<ver>, every
# release 1.0.1-1.4) lands in this repository's binaries/ directory for
# both the package suites and the --external-zlib audit mode.
# ---------------------------------------------------------------------------
ZLIB_PKG_DIR="$(pkg_dir zlib_replicant zlib-replicant)" || {
    echo "error: the zlib-replicant package was not found." >&2
    echo "  Either run 'zig build' once (this populates zig-pkg/), or clone the" >&2
    echo "  engine repository next to this one:" >&2
    echo "    git clone https://github.com/rm-netsu/zlib-replicant.git zlib-replicant" >&2
    exit 1
}
OUT_DIR="$CDIR" VENDOR_DIR="$CDIR/vendor" \
    bash "$ZLIB_PKG_DIR/binaries/build-references.sh"

# Differential matrix can build only stock zlib releases, without fetching
# optional third-party implementations.
if [[ "${ZLIB_ONLY:-0}" == "1" ]]; then
    exit 0
fi

# ---------------------------------------------------------------------------
# zlib-ng 2.2.1 (compat API)
# ---------------------------------------------------------------------------
if ! check_binary "zlib-ng-2.2.1"; then
    echo "[zlib-ng] Building zlib-ng 2.2.1..."
    dir="$VENDOR/zlib-ng-2.2.1"
    if [ ! -d "$dir" ]; then
        fetch "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/2.2.1.tar.gz" "$VENDOR/zlib-ng-2.2.1.tar.gz"
        tar -xzf "$VENDOR/zlib-ng-2.2.1.tar.gz" -C "$VENDOR"
    fi
    ( cd "$dir" \
      && ./configure --zlib-compat >/dev/null \
      && make -j"$(nproc)" >/dev/null )
    # In zlib-compat mode the library is named libz.a/libz.so (zlib-compatible).
    gcc -O3 "$CDIR/zlib_ng_wrapper.c" -I"$dir" -L"$dir" -Wl,-rpath,"$dir" -lz -o "$CDIR/zlib-ng-2.2.1$EXT"
    echo "-> built zlib-ng-2.2.1$EXT"
fi

# ---------------------------------------------------------------------------
# Zopfli 1.0.0-1.0.3 (official release CLIs) — the differential-testing
# oracles of the zopfli-replicant engine package. The vendored untouched
# 1.0.3 reference tree and the build recipe live IN the package
# (zopfli-replicant/binaries); this script delegates so one shared set of
# release CLIs lands in this repository's binaries/ directory. The other
# releases are fetched from the official tags on demand and verified
# against the package's binaries/SHA256SUMS.
# ---------------------------------------------------------------------------
ZOPFLI_PKG_DIR="$(pkg_dir zopfli_replicant zopfli-replicant)" || {
    echo "error: the zopfli-replicant package was not found." >&2
    echo "  Expected the in-tree package directory 'zopfli-replicant/'." >&2
    exit 1
}
OUT_DIR="$CDIR" VENDOR_DIR="$CDIR/vendor" \
    bash "$ZOPFLI_PKG_DIR/binaries/build-references.sh"

# ---------------------------------------------------------------------------
# libdeflate 1.20 (plain make, no cmake needed)
# ---------------------------------------------------------------------------
if ! check_binary "libdeflate-1.20"; then
    echo "[libdeflate] Building libdeflate 1.20..."
    dir="$VENDOR/libdeflate-1.20"
    if [ ! -d "$dir" ]; then
        fetch "https://github.com/ebiggers/libdeflate/archive/refs/tags/v1.20.tar.gz" "$VENDOR/libdeflate-1.20.tar.gz"
        tar -xzf "$VENDOR/libdeflate-1.20.tar.gz" -C "$VENDOR"
    fi
    # libdeflate 1.20 ships only CMake support; compile the amalgamation of
    # lib/*.c + the x86 backend directly (no cmake dependency).
    ( cd "$dir" \
      && mkdir -p build-obj \
      && for f in lib/*.c lib/x86/*.c; do \
             gcc -O3 -I. -Ilib -c "$f" -o "build-obj/$(basename "$f" .c).o" || exit 1; \
         done \
      && ar rcs libdeflate.a build-obj/*.o )
    gcc -O3 "$CDIR/libdeflate_wrapper.c" "$dir/libdeflate.a" -I"$dir" -o "$CDIR/libdeflate-1.20$EXT"
    echo "-> built libdeflate-1.20$EXT"
fi

# ---------------------------------------------------------------------------
# miniz 3.1.2 (amalgamation)
# ---------------------------------------------------------------------------
if ! check_binary "miniz-3.1.2"; then
    echo "[miniz] Building miniz 3.1.2..."
    dir="$VENDOR/miniz-3.1.2"
    if [ ! -d "$dir" ]; then
        fetch "https://github.com/richgel999/miniz/releases/download/3.1.2/miniz-3.1.2.zip" "$VENDOR/miniz-3.1.2.zip"
        mkdir -p "$dir"
        unzip -q "$VENDOR/miniz-3.1.2.zip" -d "$dir"
    fi
    # release zip layouts vary; locate miniz.c
    mfile="$(ls "$dir"/miniz.c "$dir"/*/miniz.c 2>/dev/null | head -1)"
    if [ -z "$mfile" ]; then echo "miniz.c not found"; exit 1; fi
    mdir="$(dirname "$mfile")"
    gcc -O3 "$CDIR/miniz_wrapper.c" "$mdir/miniz.c" -I"$mdir" -o "$CDIR/miniz-3.1.2$EXT"
    echo "-> built miniz-3.1.2$EXT"
fi

# ---------------------------------------------------------------------------
# AdvanceCOMP 2.6 (advdef)
# ---------------------------------------------------------------------------
if ! check_binary "advdef-2.6"; then
    echo "[advdef] Building AdvanceCOMP 2.6..."
    dir="$VENDOR/advancecomp-2.6"
    if [ ! -d "$dir" ]; then
        fetch "https://github.com/amadvance/advancecomp/releases/download/v2.6/advancecomp-2.6.tar.gz" "$VENDOR/advancecomp-2.6.tar.gz"
        tar -xzf "$VENDOR/advancecomp-2.6.tar.gz" -C "$VENDOR"
    fi
    ( cd "$dir" && ./configure >/dev/null && make -j"$(nproc)" >/dev/null )
    cp "$dir/advdef$EXT" "$CDIR/advdef-2.6$EXT"
    echo "-> built advdef-2.6$EXT"
fi

echo "=== All binaries successfully prepared! ==="
