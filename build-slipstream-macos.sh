#!/usr/bin/env bash
# ==============================================================================
# build-macos-slipstream.sh — Cross-compile slipstream-rust for macOS ABIs
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

OSXCROSS_DIR="$ROOT_DIR/osxcross"
OSXCROSS_BIN="$OSXCROSS_DIR/target/bin"
MACOS_SDK_TAR="$ROOT_DIR/MacOSX14.0.sdk.tar.xz"
DARWIN_SUFFIX="darwin23"

OPENSSL_ARM64="$ROOT_DIR/macos-openssl-arm64"
OPENSSL_X86_64="$ROOT_DIR/macos-openssl-x86_64"

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

# --- System deps ---
log "1. Installing system deps"
sudo apt-get update -y
sudo apt-get install -y \
    cmake ninja-build build-essential pkg-config \
    unzip wget git perl make gcc curl clang \
    libxml2-dev libssl-dev zlib1g-dev xz-utils \
    libbz2-dev patch lzma-dev uuid-dev

if ! command -v rustup &>/dev/null; then
    log "Installing Rust Toolchain"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source "$HOME/.cargo/env"

log "Setting up Rust deployment cross targets"
run rustup target add aarch64-apple-darwin x86_64-apple-darwin

# --- osxcross ---
log "2. Building osxcross toolchain"
if [ ! -d "$OSXCROSS_DIR" ]; then
    run git clone https://github.com/tpoechtrager/osxcross.git "$OSXCROSS_DIR"
fi
if [ ! -f "$MACOS_SDK_TAR" ]; then
    run wget --progress=bar:force:noscroll \
        "https://github.com/joseluisq/macosx-sdks/releases/download/14.0/MacOSX14.0.sdk.tar.xz" \
        -O "$MACOS_SDK_TAR"
fi
if [ ! -f "$OSXCROSS_BIN/aarch64-apple-${DARWIN_SUFFIX}-clang" ]; then
    cp "$MACOS_SDK_TAR" "$OSXCROSS_DIR/tarballs/"
    cd "$OSXCROSS_DIR"
    UNATTENDED=1 run ./build.sh
fi
export PATH="$OSXCROSS_BIN:$PATH"

# --- OpenSSL ---
log "3. OpenSSL source configuration"
if [ ! -d "$ROOT_DIR/openssl" ]; then
    run git clone https://github.com/openssl/openssl.git "$ROOT_DIR/openssl"
fi
cd "$ROOT_DIR/openssl"
run git fetch --all
run git checkout "$OPENSSL_VERSION"

build_openssl() {
    local triple="$1" config="$2" prefix="$3" min_ver="$4"
    if [ -f "$prefix/lib/libcrypto.a" ]; then
        log "OpenSSL already built for $triple — skipping"
        return 0
    fi
    log "OpenSSL for $triple"
    cd "$ROOT_DIR/openssl"
    make clean || true
    export CC="$OSXCROSS_BIN/${triple}-clang"
    export CXX="$OSXCROSS_BIN/${triple}-clang++"
    export AR="$OSXCROSS_BIN/${triple}-ar"
    export RANLIB="$OSXCROSS_BIN/${triple}-ranlib"
    run ./Configure "$config" --prefix="$prefix" no-shared no-tests "-mmacosx-version-min=$min_ver"
    run make -j"$(nproc)" build_sw
    run "$RANLIB" libcrypto.a libssl.a
    run make install_sw
}

build_openssl "aarch64-apple-${DARWIN_SUFFIX}" darwin64-arm64-cc   "$OPENSSL_ARM64"   "11.0"
build_openssl "x86_64-apple-${DARWIN_SUFFIX}"  darwin64-x86_64-cc  "$OPENSSL_X86_64"  "10.15"

cd "$PROJECT_DIR"
run git submodule update --init --recursive

# --- Build ---
build_target() {
    local arch="$1" target="$2" triple="$3" openssl_dir="$4" min_ver="$5"

    log "BUILDING DARWIN ARCHITECTURE TARGET: $arch"

    rm -rf .picoquic-build
    cargo clean

    local cc="$OSXCROSS_BIN/${triple}-clang"
    local cxx="$OSXCROSS_BIN/${triple}-clang++"
    local ar="$OSXCROSS_BIN/${triple}-ar"
    local ranlib="$OSXCROSS_BIN/${triple}-ranlib"
    local ld="$OSXCROSS_BIN/${triple}-ld"
    local flags="-arch $arch -mmacosx-version-min=$min_ver"

    local toolchain_file="/tmp/osxcross-toolchain-${arch}.cmake"
    cat > "$toolchain_file" <<EOF
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR ${arch})
set(CMAKE_C_COMPILER   "${cc}")
set(CMAKE_CXX_COMPILER "${cxx}")
set(CMAKE_AR           "${ar}" CACHE FILEPATH "")
set(CMAKE_RANLIB       "${ranlib}" CACHE FILEPATH "")
set(CMAKE_LINKER       "${ld}")
set(CMAKE_C_FLAGS_INIT   "${flags}")
set(CMAKE_CXX_FLAGS_INIT "${flags}")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${flags}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${flags}")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(PICOTLS_BUILD_CLI    OFF CACHE BOOL "" FORCE)
set(PICOTLS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
EOF

    export CARGO_BUILD_TARGET="$target"
    export CC="$cc"
    export CXX="$cxx"
    export AR="$ar"
    export RANLIB="$ranlib"
    export LD="$ld"
    export CFLAGS="$flags"
    export CXXFLAGS="$flags"
    export LDFLAGS="$flags"
    export OPENSSL_DIR="$openssl_dir"
    export OPENSSL_ROOT_DIR="$openssl_dir"
    export OPENSSL_LIB_DIR="$openssl_dir/lib"
    export OPENSSL_INCLUDE_DIR="$openssl_dir/include"
    export OPENSSL_CRYPTO_LIBRARY="$openssl_dir/lib/libcrypto.a"
    export OPENSSL_SSL_LIBRARY="$openssl_dir/lib/libssl.a"
    export OPENSSL_STATIC=1
    export OPENSSL_USE_STATIC_LIBS=ON
    export PICOQUIC_FETCH_PTLS=ON
    export BUILD_TYPE=Release
    export RUSTFLAGS="-C link-arg=-lc"
    export CARGO_FEATURE_PICOQUIC_MINIMAL_BUILD=1
    export CMAKE_TOOLCHAIN_FILE="$toolchain_file"

    local target_env="${target//-/_}"
    export "CARGO_TARGET_${target_env^^}_LINKER"="$cc"
    export "CC_${target_env}"="$cc"
    export "CXX_${target_env}"="$cxx"
    export "AR_${target_env}"="$ar"

    log "Building picoquic submodules ($arch)"
    run bash scripts/build_picoquic.sh

    log "Cargo building FFI library ($arch)"
    run cargo build --release --target "$target" \
        -p slipstream-client-ffi

    log "Verify Library Artifacts ($arch)"
    local out="target/$target/release"
    file "$out/libslipstream_client_ffi.dylib" || true
    du -h "$out/libslipstream_client_ffi.dylib" || true

    mkdir -p "$DIST_DIR"
    local out_name
    if [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
        out_name="arm64"
    else
        out_name="64"
    fi
    log "Staging library for macOS-${out_name}"
    cp "$out/libslipstream_client_ffi.dylib" "$DIST_DIR/libslipstream-client-macos-${out_name}.dylib"
}

# --- Run builds ---
build_target arm64  aarch64-apple-darwin "aarch64-apple-${DARWIN_SUFFIX}" "$OPENSSL_ARM64"   "11.0"
build_target x86_64 x86_64-apple-darwin  "x86_64-apple-${DARWIN_SUFFIX}"  "$OPENSSL_X86_64"  "10.15"

log "BUILD SUCCESS"
echo "Staged libraries in $DIST_DIR:"
ls -lh "$DIST_DIR"
