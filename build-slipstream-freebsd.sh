#!/usr/bin/env bash
# ==============================================================================
# build-slipstream-freebsd.sh — Native FreeBSD build of slipstream-rust
#
# MUST be run inside a FreeBSD system (e.g. the vmactions/freebsd-vm VM).
# It refuses to run anywhere else.
#
# Usage: ./build-slipstream-freebsd.sh <amd64|arm64>
# ==============================================================================

set -euo pipefail

# --- Guard: FreeBSD only ------------------------------------------------------
if [ "$(uname -s)" != "FreeBSD" ]; then
    echo "ERROR: this script must run on FreeBSD (detected: $(uname -s))." >&2
    echo "       In CI it runs inside the vmactions/freebsd-vm VM." >&2
    exit 1
fi

LABEL="${1:-}"
case "$LABEL" in
    amd64|arm64) ;;
    *)
        echo "Usage: $0 <amd64|arm64>" >&2
        exit 1
        ;;
esac

# FreeBSD reports "amd64" or "arm64" from `uname -m`; make sure the label matches
# the machine we're actually on (this is a native build, not a cross build).
HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" != "$LABEL" ]; then
    echo "ERROR: requested '$LABEL' but this FreeBSD machine is '$HOST_ARCH'." >&2
    echo "       This script builds natively and cannot cross-compile." >&2
    exit 1
fi

PROJECT_DIR="$PWD"
DIST_DIR="$PROJECT_DIR/dist"

if [ ! -f "$PROJECT_DIR/Cargo.toml" ]; then
    echo "ERROR: Cargo.toml not found in $PROJECT_DIR" >&2
    echo "Run this script from the root of the slipstream-rust project." >&2
    exit 1
fi

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

# --- Tooling checks -----------------------------------------------------------
log "1. Checking toolchain ($LABEL, FreeBSD $(freebsd-version))"

for tool in cmake clang clang++ git pkgconf; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: '$tool' not found. Install it with: pkg install -y $tool" >&2
        exit 1
    fi
done

# Prefer a rustup toolchain if present; otherwise use pkg's rust.
if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo not found. Install with 'pkg install -y rust' or rustup." >&2
    exit 1
fi
cargo --version
rustc --version

# --- OpenSSL (static) ---------------------------------------------------------
log "2. Locating static OpenSSL"

OPENSSL_PREFIX=""
OPENSSL_LIB=""
OPENSSL_INC=""
if [ -f /usr/local/lib/libcrypto.a ]; then
    # pkg install openssl
    OPENSSL_PREFIX=/usr/local
    OPENSSL_LIB=/usr/local/lib
    OPENSSL_INC=/usr/local/include
elif [ -f /usr/lib/libcrypto.a ]; then
    # base-system OpenSSL
    OPENSSL_PREFIX=/usr
    OPENSSL_LIB=/usr/lib
    OPENSSL_INC=/usr/include
else
    echo "ERROR: libcrypto.a not found in /usr/local/lib or /usr/lib." >&2
    echo "       Install it with: pkg install -y openssl" >&2
    exit 1
fi
echo "OpenSSL prefix: $OPENSSL_PREFIX (lib: $OPENSSL_LIB)"

export OPENSSL_DIR="$OPENSSL_PREFIX"
export OPENSSL_ROOT_DIR="$OPENSSL_PREFIX"
export OPENSSL_LIB_DIR="$OPENSSL_LIB"
export OPENSSL_INCLUDE_DIR="$OPENSSL_INC"
export OPENSSL_CRYPTO_LIBRARY="$OPENSSL_LIB/libcrypto.a"
export OPENSSL_SSL_LIBRARY="$OPENSSL_LIB/libssl.a"
export OPENSSL_STATIC=1
export OPENSSL_USE_STATIC_LIBS=ON

# --- Build environment --------------------------------------------------------
export PICOQUIC_FETCH_PTLS=ON
export BUILD_TYPE=Release
export CARGO_FEATURE_PICOQUIC_MINIMAL_BUILD=1
export CC=clang
export CXX=clang++
NCPU="$(sysctl -n hw.ncpu)"           # FreeBSD has no nproc
export CMAKE_BUILD_PARALLEL_LEVEL="$NCPU"
export CARGO_BUILD_JOBS="$NCPU"

cd "$PROJECT_DIR"

# Submodules are normally already synced from the host; this is a safety net.
git submodule update --init --recursive 2>/dev/null || \
    echo "note: git submodule update skipped (already synced from host)"

rm -rf .picoquic-build
cargo clean

# --- Build --------------------------------------------------------------------
log "3. Building picoquic submodules ($LABEL)"
run bash scripts/build_picoquic.sh

log "4. Cargo building FFI library ($LABEL)"
# Native build: no --target flag, output lands in target/release.
run cargo build --release -p slipstream-client-ffi

log "5. Verify Library Artifacts ($LABEL)"
OUT="target/release/libslipstream_client_ffi.so"
if [ ! -f "$OUT" ]; then
    echo "ERROR: expected $OUT was not produced." >&2
    ls -la target/release/ || true
    exit 1
fi
file "$OUT" || true
du -h "$OUT" || true

mkdir -p "$DIST_DIR"
log "6. Staging library for freebsd-${LABEL}"
cp "$OUT" "$DIST_DIR/libslipstream-client-freebsd-${LABEL}.so"

log "BUILD SUCCESS"
echo "Outputs staged in $DIST_DIR:"
ls -lh "$DIST_DIR"
