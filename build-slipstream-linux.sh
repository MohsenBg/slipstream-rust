#!/usr/bin/env bash
# ==============================================================================
# build-linux-slipstream.sh — Cross-compile slipstream-rust for Linux ABIs
# ==============================================================================

set -euo pipefail

OPENSSL_VERSION="openssl-3.5"
ROOT_DIR="$HOME"
PROJECT_DIR="$PWD"
DIST_DIR="$PROJECT_DIR/dist"

if [ ! -f "$PROJECT_DIR/Cargo.toml" ]; then
    echo "ERROR: Cargo.toml not found in $PROJECT_DIR"
    echo "Run this script from the root of the slipstream-rust project."
    exit 1
fi

TARGETS=(
    "arm64"
    "arm32"
    "amd64"
    "amd32"
)

log() {
    echo
    echo "======================================"
    echo "$*"
    echo "======================================"
}

run() {
    echo "+ $*"
    "$@"
}

openssl_lib_dir() {
    local prefix="$1"
    if [ -f "$prefix/lib/libcrypto.a" ]; then
        echo "$prefix/lib"
    elif [ -f "$prefix/lib64/libcrypto.a" ]; then
        echo "$prefix/lib64"
    else
        echo ""
    fi
}

# --- System deps ---
log "1. Installing system deps"
sudo apt-get update -y
sudo apt-get install -y \
    cmake ninja-build build-essential pkg-config \
    unzip wget git perl make gcc curl clang \
    libxml2-dev libssl-dev zlib1g-dev xz-utils \
    libbz2-dev patch uuid-dev \
    gcc-aarch64-linux-gnu   g++-aarch64-linux-gnu   binutils-aarch64-linux-gnu \
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf binutils-arm-linux-gnueabihf \
    gcc-i686-linux-gnu      g++-i686-linux-gnu      binutils-i686-linux-gnu

if ! command -v rustup &>/dev/null; then
    log "Installing Rust Toolchain"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source "$HOME/.cargo/env"

log "Setting up Rust deployment cross targets"
run rustup target add \
    aarch64-unknown-linux-gnu \
    armv7-unknown-linux-gnueabihf \
    x86_64-unknown-linux-gnu \
    i686-unknown-linux-gnu

mkdir -p "$DIST_DIR"

# --- OpenSSL ---
log "2. OpenSSL source configuration"
if [ ! -d "$ROOT_DIR/openssl-src" ]; then
    run git clone https://github.com/openssl/openssl.git "$ROOT_DIR/openssl-src"
fi
cd "$ROOT_DIR/openssl-src"
run git fetch --all
run git checkout "$OPENSSL_VERSION"

build_openssl() {
    local label="$1" config="$2" prefix="$3" cc="$4" ar="$5" ranlib="$6"
    local lib_dir
    lib_dir="$(openssl_lib_dir "$prefix")"
    if [ -n "$lib_dir" ]; then
        log "OpenSSL already built for $label at $lib_dir — skipping"
        return 0
    fi
    log "Building OpenSSL for $label"
    cd "$ROOT_DIR/openssl-src"
    make clean || true
    CC="$cc" AR="$ar" RANLIB="$ranlib" \
    run ./Configure "$config" --prefix="$prefix" no-shared no-tests
    CC="$cc" AR="$ar" RANLIB="$ranlib" \
    run make -j"$(nproc)" build_sw
    "$ranlib" libcrypto.a libssl.a
    run make install_sw
}

build_openssl "arm64" "linux-aarch64" "$ROOT_DIR/linux-openssl-arm64" \
    "aarch64-linux-gnu-gcc" "aarch64-linux-gnu-ar" "aarch64-linux-gnu-ranlib"
build_openssl "arm32" "linux-armv4" "$ROOT_DIR/linux-openssl-arm32" \
    "arm-linux-gnueabihf-gcc" "arm-linux-gnueabihf-ar" "arm-linux-gnueabihf-ranlib"
build_openssl "amd64" "linux-x86_64" "$ROOT_DIR/linux-openssl-amd64" \
    "gcc" "ar" "ranlib"
build_openssl "amd32" "linux-x86" "$ROOT_DIR/linux-openssl-amd32" \
    "i686-linux-gnu-gcc" "i686-linux-gnu-ar" "i686-linux-gnu-ranlib"

cd "$PROJECT_DIR"
run git submodule update --init --recursive

# --- Build ---
build_target() {
    local label="$1" rust_target="$2" triple="$3" cc="$4" cxx="$5" \
          ar="$6" ranlib="$7" openssl_prefix="$8" extra_cflags="${9:-}" no_fusion="${10:-0}"

    log "BUILDING LINUX ARCHITECTURE TARGET: $label ($rust_target)"

    local openssl_lib
    openssl_lib="$(openssl_lib_dir "$openssl_prefix")"
    if [ -z "$openssl_lib" ]; then
        echo "ERROR: libcrypto.a not found under $openssl_prefix/lib or $openssl_prefix/lib64"
        exit 1
    fi

    cd "$PROJECT_DIR"
    rm -rf .picoquic-build
    cargo clean

    local flags="$extra_cflags"
    local toolchain_file="/tmp/linux-toolchain-${label}.cmake"
    cat > "$toolchain_file" << EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_C_COMPILER   "${cc}")
set(CMAKE_CXX_COMPILER "${cxx}")
set(CMAKE_AR           "${ar}" CACHE FILEPATH "")
set(CMAKE_RANLIB       "${ranlib}" CACHE FILEPATH "")
set(CMAKE_C_FLAGS_INIT   "${flags}")
set(CMAKE_CXX_FLAGS_INIT "${flags}")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${flags}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${flags}")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(PICOTLS_BUILD_CLI    OFF CACHE BOOL "" FORCE)
set(PICOTLS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
EOF
    if [ "$no_fusion" == "1" ]; then
        cat >> "$toolchain_file" << EOF
set(PTLS_BUILD_FUSION OFF CACHE BOOL "" FORCE)
set(WITH_FUSION       OFF CACHE BOOL "" FORCE)
EOF
    fi

    export CARGO_BUILD_TARGET="$rust_target"
    export CC="$cc"
    export CXX="$cxx"
    export AR="$ar"
    export RANLIB="$ranlib"
    export CFLAGS="$flags"
    export CXXFLAGS="$flags"
    export LDFLAGS="$flags"
    export OPENSSL_DIR="$openssl_prefix"
    export OPENSSL_ROOT_DIR="$openssl_prefix"
    export OPENSSL_LIB_DIR="$openssl_lib"
    export OPENSSL_INCLUDE_DIR="$openssl_prefix/include"
    export OPENSSL_CRYPTO_LIBRARY="$openssl_lib/libcrypto.a"
    export OPENSSL_SSL_LIBRARY="$openssl_lib/libssl.a"
    export OPENSSL_STATIC=1
    export OPENSSL_USE_STATIC_LIBS=ON
    export PICOQUIC_FETCH_PTLS=ON
    export BUILD_TYPE=Release
    export RUSTFLAGS="-C link-arg=-lc"
    export CARGO_FEATURE_PICOQUIC_MINIMAL_BUILD=1
    export CMAKE_TOOLCHAIN_FILE="$toolchain_file"

    local target_env="${rust_target//-/_}"
    export "CARGO_TARGET_${target_env^^}_LINKER"="$cc"
    export "CC_${target_env}"="$cc"
    export "CXX_${target_env}"="$cxx"
    export "AR_${target_env}"="$ar"

    log "Building picoquic submodules ($label)"
    run bash scripts/build_picoquic.sh

    log "Cargo building FFI library ($label)"
    run cargo build --release --target "$rust_target" \
        -p slipstream-client-ffi

    log "Verify Library Artifacts ($label)"
    local out="target/$rust_target/release"
    file "$OUT/libslipstream_client_ffi.so" || true
    du -h "$OUT/libslipstream_client_ffi.so" || true

    local norm_arch="$label"
    if [ "$label" == "arm64" ]; then norm_arch="armv8"
    elif [ "$label" == "arm32" ]; then norm_arch="armv7"
    elif [ "$label" == "amd32" ]; then norm_arch="386"; fi

    log "Staging library for linux-${norm_arch}"
    cp "$out/libslipstream_client_ffi.so" "$DIST_DIR/libslipstream-client-linux-${norm_arch}.so"
}

# --- Run builds ---
for tgt in "${TARGETS[@]}"; do
    case "$tgt" in
        arm64)
            build_target "arm64" "aarch64-unknown-linux-gnu" "aarch64-linux-gnu" \
                "aarch64-linux-gnu-gcc" "aarch64-linux-gnu-g++" \
                "aarch64-linux-gnu-ar" "aarch64-linux-gnu-ranlib" \
                "$ROOT_DIR/linux-openssl-arm64" "" "0"
            ;;
        arm32)
            build_target "arm32" "armv7-unknown-linux-gnueabihf" "arm-linux-gnueabihf" \
                "arm-linux-gnueabihf-gcc" "arm-linux-gnueabihf-g++" \
                "arm-linux-gnueabihf-ar" "arm-linux-gnueabihf-ranlib" \
                "$ROOT_DIR/linux-openssl-arm32" \
                "-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard" "1"
            ;;
        amd64)
            build_target "amd64" "x86_64-unknown-linux-gnu" "x86_64-linux-gnu" \
                "gcc" "g++" "ar" "ranlib" \
                "$ROOT_DIR/linux-openssl-amd64" "" "0"
            ;;
        amd32)
            build_target "amd32" "i686-unknown-linux-gnu" "i686-linux-gnu" \
                "i686-linux-gnu-gcc" "i686-linux-gnu-g++" \
                "i686-linux-gnu-ar" "i686-linux-gnu-ranlib" \
                "$ROOT_DIR/linux-openssl-amd32" "-m32" "1"
            ;;
        *)
            echo "Unknown runtime architecture target sequence: $tgt — skipping"
            ;;
    esac
done

log "BUILD SUCCESS"
echo "Outputs Staged in $DIST_DIR:"
ls -lh "$DIST_DIR"
