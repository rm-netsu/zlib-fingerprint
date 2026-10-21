#!/usr/bin/env bash
set -e

CDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CDIR"

echo "=== Preparing binaries in directory: $CDIR ==="

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    EXT=".exe"
else
    EXT=""
fi

if [ ! -f "zlib_wrapper.c" ]; then
    echo "Error: zlib_wrapper.c not found in $CDIR!"
    exit 1
fi

# Функция проверки наличия бинарника
check_binary() {
    local name="$1"
    local bin_file="$name$EXT"
    if [ -f "$bin_file" ]; then
        echo "-> [SKIP] $bin_file already exists."
        return 0
    fi
    return 1
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. zlib 1.2.3
if ! check_binary "zlib-1.2.3"; then
    echo "[1/10] Building zlib 1.2.3..."
    cd "$TMP_DIR"
    curl -L https://www.zlib.net/fossils/zlib-1.2.3.tar.gz -o zlib-1.2.3.tar.gz
    tar -xzf zlib-1.2.3.tar.gz
    cd zlib-1.2.3
    gcc -O3 "$CDIR/zlib_wrapper.c" -I. -L. -lz -o "zlib-1.2.3$EXT"
    cp "zlib-1.2.3$EXT" "$CDIR/zlib-1.2.3$EXT"
    cd "$CDIR"
    rm -rf "$TMP_DIR/*"
fi

# 2. zlib 1.2.5
if ! check_binary "zlib-1.2.5"; then
    echo "[2/10] Building zlib 1.2.5..."
    cd "$TMP_DIR"
    curl -L https://www.zlib.net/fossils/zlib-1.2.5.tar.gz -o zlib-1.2.5.tar.gz
    tar -xzf zlib-1.2.5.tar.gz
    cd zlib-1.2.5
    gcc -O3 "$CDIR/zlib_wrapper.c" -I. -L. -lz -o "zlib-1.2.5$EXT"
    cp "zlib-1.2.5$EXT" "$CDIR/zlib-1.2.5$EXT"
    cd "$CDIR"
    rm -rf "$TMP_DIR/*"
fi

# 3. zlib 1.2.7
if ! check_binary "zlib-1.2.7"; then
    echo "[3/10] Building zlib 1.2.7..."
    cd "$TMP_DIR"
    curl -L https://www.zlib.net/fossils/zlib-1.2.7.tar.gz -o zlib-1.2.7.tar.gz
    tar -xzf zlib-1.2.7.tar.gz
    cd zlib-1.2.7
    gcc -O3 "$CDIR/zlib_wrapper.c" -I. -L. -lz -o "zlib-1.2.7$EXT"
    cp "zlib-1.2.7$EXT" "$CDIR/zlib-1.2.7$EXT"
    cd "$CDIR"
    rm -rf "$TMP_DIR/*"
fi

# 4. zlib 1.2.8
if ! check_binary "zlib-1.2.8"; then
    echo "[4/10] Building zlib 1.2.8..."
    cd "$TMP_DIR"
    curl -L https://www.zlib.net/fossils/zlib-1.2.8.tar.gz -o zlib-1.2.8.tar.gz
    tar -xzf zlib-1.2.8.tar.gz
    cd zlib-1.2.8
    gcc -O3 "$CDIR/zlib_wrapper.c" -I. -L. -lz -o "zlib-1.2.8$EXT"
    cp "zlib-1.2.8$EXT" "$CDIR/zlib-1.2.8$EXT"
    cd "$CDIR"
    rm -rf "$TMP_DIR/*"
fi

# 5. zlib 1.2.11
if ! check_binary "zlib-1.2.11"; then
    echo "[5/10] Building zlib 1.2.11..."
    cd "$TMP_DIR"
    curl -L https://www.zlib.net/fossils/zlib-1.2.11.tar.gz -o zlib-1.2.11.tar.gz
    tar -xzf zlib-1.2.11.tar.gz
    cd zlib-1.2.11
    gcc -O3 "$CDIR/zlib_wrapper.c" -I. -L. -lz -o "zlib-1.2.11$EXT"
    cp "zlib-1.2.11$EXT" "$CDIR/zlib-1.2.11$EXT"
    cd "$CDIR"
    rm -rf "$TMP_DIR/*"
fi

# 6. zlib 1.3.1
if ! check_binary "zlib-1.3.1"; then
    echo "[6/10] Building zlib 1.3.1..."
    cd "$TMP_DIR"
    curl -L https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz -o zlib-1.3.1.tar.gz
    tar -xzf zlib-1.3.1.tar.gz
    cd zlib-1.3.1
    gcc -O3 "$CDIR/zlib_wrapper.c" -I. -L. -lz -o "zlib-1.3.1$EXT"
    cp "zlib-1.3.1$EXT" "$CDIR/zlib-1.3.1$EXT"
    cd "$CDIR"
    rm -rf "$TMP_DIR/*"
fi

# 7. Zopfli 1.0.3
if ! check_binary "zopfli-1.0.3"; then
    echo "[7/10] Building Zopfli 1.0.3..."
    cd "$TMP_DIR"
    curl -L https://github.com/google/zopfli/archive/refs/tags/zopfli-1.0.3.tar.gz -o zopfli-1.0.3.tar.gz
    tar -xzf zopfli-1.0.3.tar.gz
    cd zopfli-zopfli-1.0.3
    make zopfli
    if [ -f "zopfli$EXT" ]; then
        cp "zopfli$EXT" "$CDIR/zopfli-1.0.3$EXT"
    fi
    cd "$CDIR"
fi

# 8. libdeflate 1.20
if ! check_binary "libdeflate-1.20"; then
    echo "[8/10] Building libdeflate 1.20..."
    cd "$TMP_DIR"
    curl -L https://github.com/ebiggers/libdeflate/archive/refs/tags/v1.20.tar.gz -o libdeflate.tar.gz
    tar -xzf libdeflate.tar.gz
    cd libdeflate-1.20
    
    # Собираем через cmake
    cmake -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j$(nproc)
    
    # Компилируем нашу обертку, линкуя со статичной библиотекой libdeflate
    gcc -O3 "$CDIR/libdeflate_wrapper.c" build/libdeflate.a -I. -o "libdeflate$EXT"
    cp "libdeflate$EXT" "$CDIR/libdeflate-1.20$EXT"
    cd "$CDIR"
fi

# 9. miniz
if ! check_binary "miniz-3.1.2"; then
    echo "[9/10] Building miniz from release zip..."
    cd "$TMP_DIR"
    
    curl -L https://github.com/richgel999/miniz/releases/download/3.1.2/miniz-3.1.2.zip -o miniz.zip
    unzip -q miniz.zip
    
    # В архиве miniz файлы могут лежать в корне или в папке. 
    # Найдем miniz.c и miniz.h или скопируем из текущей распакованной структуры.
    # Обычно в релизах miniz поставляется как единая пара miniz.c / miniz.h или через cmake.
    # Если релиз использует CMake, соберем через cmake или возьмем корневые файлы.
    
    # Проверим наличие miniz.c прямо в распакованном или перейдем в папку сборки
    if [ -f "miniz.c" ]; then
        gcc -O3 "$CDIR/miniz_wrapper.c" miniz.c -I. -o "miniz$EXT"
    else
        # Если релиз требует cmake-сборки самой библиотеки miniz
        cmake -B build -DCMAKE_BUILD_TYPE=Release
        cmake --build build -j$(nproc)
        # Линкуем со статической библиотекой miniz
        gcc -O3 "$CDIR/miniz_wrapper.c" build/libminiz.a -Iminiz-path-if-needed -o "miniz$EXT" 2>/dev/null || \
        gcc -O3 "$CDIR/miniz_wrapper.c" build/libminiz.a -I. -o "miniz$EXT"
    fi
    
    cp "miniz$EXT" "$CDIR/miniz-3.1.2$EXT"
    cd "$CDIR"
fi

# 10. AdvanceCOMP (advdef) - оптимизатор сырых DEFLATE/zlib потоков
if ! check_binary "advdef-2.6"; then
    echo "[10/10] Building AdvanceCOMP (advdef)..."
    cd "$TMP_DIR"
    if [ ! -f "advancecomp-2.6.tar.gz" ]; then
        curl -L https://github.com/amadvance/advancecomp/releases/download/v2.6/advancecomp-2.6.tar.gz -o advancecomp-2.6.tar.gz
    fi
    tar -xzf advancecomp-2.6.tar.gz
    cd advancecomp-2.6
    ./configure
    make -j$(nproc)
    cp advdef$EXT "$CDIR/advdef-2.6$EXT"
    cd "$CDIR"
fi

echo "=== All binaries successfully prepared! ==="
