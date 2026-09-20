#!/usr/bin/env bash
# ==============================================================================
# release.sh — Stage 2 asset packaging. Copies libslipstream-client-*
# artifacts directly (no tar), computes SHA-256 checksums, and generates
# Markdown release notes.
# Requirement: STRICTLY requires the release tag version as the 1st argument.
# ==============================================================================

set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
if [ "${1:-}" = "" ]; then
  echo "USAGE: $0 <tag_version>" >&2
  exit 1
fi

TAG_VERSION="$1"
DIST_DIR="$PWD/dist"
RELEASE_DIR="$PWD/release"
CHECKSUM_FILE="$RELEASE_DIR/checksum.txt"
NOTES_FILE="$RELEASE_DIR/release_notes.md"

REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-user/repo}"

log() {
  echo
  echo "======================================"
  echo "$*"
  echo "======================================"
}

# ==============================================================================
# PREREQUISITES
# ==============================================================================
log "1. Installing release runner dependencies (Targeting: $TAG_VERSION)"
sudo apt-get update -y
sudo apt-get install -y coreutils

for cmd in sha256sum; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: Required system tool '$cmd' is missing." >&2
    exit 1
  fi
done

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

if [ ! -d "$DIST_DIR" ] || [ -z "$(ls -A "$DIST_DIR" 2>/dev/null)" ]; then
  log "ERROR: The directory '$DIST_DIR' is missing or empty. Nothing to release."
  exit 1
fi

# ==============================================================================
# COPY BINARIES DIRECTLY (no tar)
# ==============================================================================
log "2. Copying artifacts from dist/ to release/"

cd "$DIST_DIR"

for asset in libslipstream-client-*; do
  [ -f "$asset" ] || continue
  log "Copying: $asset"
  cp "$asset" "$RELEASE_DIR/$asset"
done

log "3. Generating SHA-256 checksums"
: >"$CHECKSUM_FILE"
cd "$RELEASE_DIR"
for asset in libslipstream-client-*; do
  [ -f "$asset" ] || continue
  sha256sum "$asset" >>"$CHECKSUM_FILE"
done

# ==============================================================================
# MARKDOWN RELEASE NOTES
# ==============================================================================
log "4. Generating release notes"

get_link() {
  local name="$1"
  local clean_repo="${REPO_URL%/}"
  echo "[$2]($clean_repo/releases/download/$TAG_VERSION/$name)"
}

: >"$NOTES_FILE"

cat <<EOF >>"$NOTES_FILE"
# Slipstream Release Package ($TAG_VERSION)

This release contains the verified, automated builds for **Slipstream** FFI libraries.

---

## Download Links

| Platform / Architecture | Download Link |
| :--- | :--- |
EOF

# Android
for arch in arm64-v8a armeabi-v7a x86 x86_64; do
  name="libslipstream-client-android-${arch}.so"
  label="$(echo "$arch" | sed 's/arm64-v8a/ARM64 (v8a)/;s/armeabi-v7a/ARMv7/;s/x86_64/AMD64/;s/x86/Intel x86/')"
  echo "| 🤖 **Android** ${label} | $(get_link "$name" "📦 $name") |" >>"$NOTES_FILE"
done

# Linux
for arch in arm64 arm32-v7a 64 32; do
  name="libslipstream-client-linux-${arch}.so"
  label="$(echo "$arch" | sed 's/arm64/ARM64/;s/arm32-v7a/ARMv7/;s/^64$/AMD64/;s/^32$/32-bit/')"
  echo "| 🐧 **Linux** ${label} | $(get_link "$name" "📦 $name") |" >>"$NOTES_FILE"
done

# macOS
for arch in arm64 64; do
  name="libslipstream-client-macos-${arch}.dylib"
  label="$(echo "$arch" | sed 's/arm64/Apple Silicon ARM64/;s/^64$/Intel x86_64/')"
  echo "| 🍏 **macOS** ${label} | $(get_link "$name" "📦 $name") |" >>"$NOTES_FILE"
done

# FreeBSD
for arch in amd64 arm64; do
  name="libslipstream-client-freebsd-${arch}.so"
  label="$(echo "$arch" | sed 's/amd64/AMD64/;s/arm64/ARM64/')"
  echo "| 🔵 **FreeBSD** ${label} | $(get_link "$name" "📦 $name") |" >>"$NOTES_FILE"
done

# Windows
for arch in amd64 arm64; do
  name="libslipstream-client-windows-${arch}.dll"
  label="$(echo "$arch" | sed 's/amd64/AMD64/;s/arm64/ARM64/')"
  echo "| 🪟 **Windows** ${label} | $(get_link "$name" "📦 $name") |" >>"$NOTES_FILE"
done

log "RELEASE MET SUCCESSFUL WITH TAG: $TAG_VERSION"
