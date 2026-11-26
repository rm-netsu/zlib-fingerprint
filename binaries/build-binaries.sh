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

# ---------------------------------------------------------------------------
# zlib family (official versions) via zlib_wrapper.c
# ---------------------------------------------------------------------------
build_zlib() { # build_zlib <version> <url>
    local ver="$1" url="$2"
    if check_binary "zlib-$ver"; then return 0; fi
    echo "[zlib] Building zlib $ver..."
    local dir
    if [ -d "$VENDOR/zlib-$ver" ]; then
        dir="$VENDOR/zlib-$ver"
    elif [ -d "$VENDOR/zlib-v$ver" ]; then
        dir="$VENDOR/zlib-v$ver"
    else
        fetch "$url" "$VENDOR/zlib-$ver.tar.gz"
        tar -xzf "$VENDOR/zlib-$ver.tar.gz" -C "$VENDOR"
        if [ -d "$VENDOR/zlib-v$ver" ]; then dir="$VENDOR/zlib-v$ver"; else dir="$VENDOR/zlib-$ver"; fi
    fi
    # Build the REAL version library first; linking against it is what makes
    # the wrapper genuinely reproduce this version's bitstream behavior
    # (linking -lz against the system lib would silently fake the version).
    ( cd "$dir" \
      && ./configure --static >/dev/null 2>&1 \
      && make -j"$(nproc)" libz.a >/dev/null 2>&1 )
    ( cd "$dir" && gcc -O3 "$CDIR/zlib_wrapper.c" -I. -L. -lz -o "$CDIR/zlib-$ver$EXT" )
    echo "-> built zlib-$ver$EXT"
}

# Scenario-driven streaming wrapper (chunked input, flush operations, capped
# avail_out, deflateParams/SetDictionary/Reset/Copy) around the same
# version-specific static library.
build_zstream() { # build_zstream <version> <url>
    local ver="$1" url="$2"
    if check_binary "zstream-$ver"; then return 0; fi
    echo "[zstream] Building zstream $ver..."
    local dir
    if [ -d "$VENDOR/zlib-$ver" ]; then
        dir="$VENDOR/zlib-$ver"
    elif [ -d "$VENDOR/zlib-v$ver" ]; then
        dir="$VENDOR/zlib-v$ver"
    else
        fetch "$url" "$VENDOR/zlib-$ver.tar.gz"
        tar -xzf "$VENDOR/zlib-$ver.tar.gz" -C "$VENDOR"
        if [ -d "$VENDOR/zlib-v$ver" ]; then dir="$VENDOR/zlib-v$ver"; else dir="$VENDOR/zlib-$ver"; fi
    fi
    ( cd "$dir" \
      && ./configure --static >/dev/null 2>&1 \
      && make -j"$(nproc)" libz.a >/dev/null 2>&1 )
    ( cd "$dir" && gcc -O2 "$CDIR/zstream_wrapper.c" -I. -L. -lz -o "$CDIR/zstream-$ver$EXT" )
    echo "-> built zstream-$ver$EXT"
}

GITHUB_ZLIB="https://github.com/madler/zlib/archive/refs/tags"
# Historical, potentially bitstream-distinct releases. These are deliberately
# NOT marked covered by the integrated 1.2.3+ engine. All versions are
# fetched from the upstream GitHub mirror (faster than zlib.net/fossils and
# serving identical release sources); the only tag missing there is v1.0.6,
# which keeps the fossils URL.
for ver in 1.0.1 1.0.2 1.0.4 1.0.5 1.0.7 1.0.8 1.0.9 \
           1.1.0 1.1.1 1.1.2 1.1.3 1.1.4; do
    build_zlib "$ver" "$GITHUB_ZLIB/v$ver.tar.gz"
    build_zstream "$ver" "$GITHUB_ZLIB/v$ver.tar.gz"
done
build_zlib    "1.0.6" "https://zlib.net/fossils/zlib-1.0.6.tar.gz"
build_zstream "1.0.6" "https://zlib.net/fossils/zlib-1.0.6.tar.gz"
for ver in 1.2.0 1.2.1 1.2.2; do
    build_zlib "$ver" "$GITHUB_ZLIB/v$ver.tar.gz"
    build_zstream "$ver" "$GITHUB_ZLIB/v$ver.tar.gz"
done
for ver in 1.2.3 1.2.4 1.2.5 1.2.6 1.2.7 1.2.8 1.2.9 1.2.10 1.2.11 \
           1.2.12 1.2.13 1.3; do
    build_zlib "$ver" "$GITHUB_ZLIB/v$ver.tar.gz"
    build_zstream "$ver" "$GITHUB_ZLIB/v$ver.tar.gz"
done
build_zlib    "1.3.1" "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
build_zstream "1.3.1" "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
build_zlib    "1.3.2" "$GITHUB_ZLIB/v1.3.2.tar.gz"
build_zstream "1.3.2" "$GITHUB_ZLIB/v1.3.2.tar.gz"
build_zlib    "1.4" "$GITHUB_ZLIB/v1.4.tar.gz"
build_zstream "1.4" "$GITHUB_ZLIB/v1.4.tar.gz"

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
# Zopfli 1.0.3
# ---------------------------------------------------------------------------
if ! check_binary "zopfli-1.0.3"; then
    echo "[zopfli] Building Zopfli 1.0.3..."
    dir="$VENDOR/zopfli-zopfli-1.0.3"
    if [ ! -d "$dir" ]; then
        fetch "https://github.com/google/zopfli/archive/refs/tags/zopfli-1.0.3.tar.gz" "$VENDOR/zopfli-1.0.3.tar.gz"
        tar -xzf "$VENDOR/zopfli-1.0.3.tar.gz" -C "$VENDOR"
    fi
    ( cd "$dir" && make zopfli >/dev/null )
    cp "$dir/zopfli$EXT" "$CDIR/zopfli-1.0.3$EXT"
    echo "-> built zopfli-1.0.3$EXT"
fi

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
