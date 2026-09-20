#!/usr/bin/env bash
# ==============================================================================
# build-android-slipstream.sh — Cross-compile slipstream-rust for Android ABIs
# ==============================================================================

set -euo pipefail

API=21
NDK_VERSION="r27d"
OPENSSL_VERSION="openssl-3.5"

ROOT_DIR="$HOME"
PROJECT_DIR="$PWD"
DIST_DIR="$PROJECT_DIR/dist"

if [ ! -f "$PROJECT_DIR/Cargo.toml" ]; then
    echo "ERROR: Cargo.toml not found in $PROJECT_DIR"
    echo "Run this script from the root of the slipstream-rust project."
    exit 1
fi

NDK_DIR="$ROOT_DIR/android-ndk-$NDK_VERSION"
NDK_BIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
SYSROOT="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

OPENSSL_ARM64="$ROOT_DIR/android-openssl-arm64"
OPENSSL_ARM32="$ROOT_DIR/android-openssl-armv7"
OPENSSL_X86="$ROOT_DIR/android-openssl-x86"
OPENSSL_X86_64="$ROOT_DIR/android-openssl-x86_64"

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

# --- Prerequisites ---
log "1. Installing system deps"
sudo apt-get update -y
sudo apt-get install -y \
    cmake ninja-build build-essential pkg-config unzip wget git perl make gcc curl

if ! command -v rustup &>/dev/null; then
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source "$HOME/.cargo/env"
rustup default stable

log "Installing Rust Android targets"
run rustup target add \
    aarch64-linux-android \
    armv7-linux-androideabi \
    i686-linux-android \
    x86_64-linux-android

log "Installing cargo-ndk"
if ! command -v cargo-ndk &>/dev/null; then
    run cargo install cargo-ndk
fi

# --- Android NDK ---
log "2. Android NDK"
if [ ! -d "$NDK_DIR" ]; then
    run wget --progress=bar:force:noscroll \
        "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" \
        -O "$ROOT_DIR/ndk.zip"
    run unzip -q "$ROOT_DIR/ndk.zip" -d "$ROOT_DIR"
    rm -f "$ROOT_DIR/ndk.zip"
fi
export ANDROID_NDK_HOME="$NDK_DIR"
export ANDROID_NDK_ROOT="$NDK_DIR"
export NDK_HOME="$NDK_DIR"
export PATH="$NDK_BIN:$PATH"

# --- OpenSSL ---
log "3. OpenSSL source setup"
if [ ! -d "$ROOT_DIR/openssl" ]; then
    run git clone https://github.com/openssl/openssl.git "$ROOT_DIR/openssl"
fi
cd "$ROOT_DIR/openssl"
run git fetch --all
run git checkout "$OPENSSL_VERSION"

build_openssl() {
    local label="$1" config="$2" prefix="$3"
    if [ -f "$prefix/lib/libcrypto.a" ]; then
        log "OpenSSL already built for $label — skipping"
        return 0
    fi
    log "Building OpenSSL for $label"
    cd "$ROOT_DIR/openssl"
    make clean || true
    run ./Configure "$config" -D__ANDROID_API__=$API --prefix="$prefix" no-shared
    run make -j"$(nproc)"
    run make install_sw
}

build_openssl "arm64" "android-arm64" "$OPENSSL_ARM64"
build_openssl "arm32" "android-arm" "$OPENSSL_ARM32"
build_openssl "x86" "android-x86" "$OPENSSL_X86"
build_openssl "x86_64" "android-x86_64" "$OPENSSL_X86_64"

cd "$PROJECT_DIR"
run git submodule update --init --recursive

# --- Build ---
build_target() {
    local ABI="$1" TARGET="$2" CLANG="$3" OPENSSL_DIR="$4"

    log "BUILDING ABI TARGET: $ABI"
    rm -rf .picoquic-build
    cargo clean

    export ANDROID_ABI="$ABI"
    export ANDROID_PLATFORM="android-$API"
    export TARGET="$TARGET"
    export CARGO_BUILD_TARGET="$TARGET"
    export CC="$NDK_BIN/$CLANG"
    export CXX="${CC}++"
    export AR="$NDK_BIN/llvm-ar"
    export RANLIB="$NDK_BIN/llvm-ranlib"
    export LD="$NDK_BIN/ld"
    export PATH="$NDK_BIN:$PATH"
    export SYSROOT="$SYSROOT"
    export CFLAGS="--target=${TARGET}${API} --sysroot=$SYSROOT"
    export CXXFLAGS="$CFLAGS"
    export OPENSSL_DIR="$OPENSSL_DIR"
    export OPENSSL_ROOT_DIR="$OPENSSL_DIR"
    export OPENSSL_LIB_DIR="$OPENSSL_DIR/lib"
    export OPENSSL_INCLUDE_DIR="$OPENSSL_DIR/include"
    export OPENSSL_CRYPTO_LIBRARY="$OPENSSL_DIR/lib/libcrypto.a"
    export OPENSSL_SSL_LIBRARY="$OPENSSL_DIR/lib/libssl.a"
    export OPENSSL_STATIC=1
    export OPENSSL_USE_STATIC_LIBS=ON
    export PICOQUIC_FETCH_PTLS=ON
    export BUILD_TYPE=Release
    export RUSTFLAGS="-C link-arg=-lc -C link-arg=-ldl -C link-arg=-llog -C link-arg=-lunwind"

    case "$TARGET" in
        aarch64-linux-android)
            export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC"
            export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$AR"
            export CC_aarch64_linux_android="$CC"
            export CXX_aarch64_linux_android="$CXX"
            export AR_aarch64_linux_android="$AR"
            ;;
        armv7-linux-androideabi)
            export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER="$CC"
            export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_AR="$AR"
            export CC_armv7_linux_androideabi="$CC"
            export CXX_armv7_linux_androideabi="$CXX"
            export AR_armv7_linux_androideabi="$AR"
            ;;
        i686-linux-android)
            export CARGO_TARGET_I686_LINUX_ANDROID_LINKER="$CC"
            export CARGO_TARGET_I686_LINUX_ANDROID_AR="$AR"
            export CC_i686_linux_android="$CC"
            export CXX_i686_linux_android="$CXX"
            export AR_i686_linux_android="$AR"
            ;;
        x86_64-linux-android)
            export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$CC"
            export CARGO_TARGET_X86_64_LINUX_ANDROID_AR="$AR"
            export CC_x86_64_linux_android="$CC"
            export CXX_x86_64_linux_android="$CXX"
            export AR_x86_64_linux_android="$AR"
            ;;
    esac

    log "Building picoquic submodules ($ABI)"
    run bash scripts/build_picoquic.sh

    log "Cargo building FFI library ($ABI)"
    run cargo ndk \
        -t "$ABI" \
        build \
        --release \
        -p slipstream-client-ffi

    log "Verify Library Artifacts ($ABI)"
    local out="target/$TARGET/release"
    file "$OUT/libslipstream_client_ffi.so" || true
    du -h "$OUT/libslipstream_client_ffi.so" || true

    local final_arch
    case "$ABI" in
        "arm64-v8a")   final_arch="arm64" ;;
        "armeabi-v7a") final_arch="armv7" ;;
        "x86")         final_arch="x86"   ;;
        "x86_64")      final_arch="amd64" ;;
        *)             final_arch="$ABI"  ;;
    esac

    mkdir -p "$DIST_DIR"
    log "Staging library for android-${final_arch}"
    cp "$OUT/libslipstream_client_ffi.so" "$DIST_DIR/libslipstream-client-android-${final_arch}.so"
    chmod +x "$DIST_DIR/libslipstream-client-android-${final_arch}.so"
}

# --- Run builds ---
build_target arm64-v8a aarch64-linux-android aarch64-linux-android21-clang "$OPENSSL_ARM64"
build_target x86 i686-linux-android i686-linux-android21-clang "$OPENSSL_X86"
build_target armeabi-v7a armv7-linux-androideabi armv7a-linux-androideabi21-clang "$OPENSSL_ARM32"
build_target x86_64 x86_64-linux-android x86_64-linux-android21-clang "$OPENSSL_X86_64"

log "BUILD SUCCESS"
echo "Staged libraries in $DIST_DIR:"
ls -lh "$DIST_DIR"
