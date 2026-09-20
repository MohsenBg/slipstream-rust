#!/usr/bin/env bash
# ==============================================================================
# release.sh — Stage 2 asset packaging. Archives libslipstream-client-*
# artifacts, computes SHA-256 checksums, and generates Markdown release notes.
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
sudo apt-get install -y tar coreutils

for cmd in sha256sum tar; do
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

ARCHIVES=()

# ==============================================================================
# ARCHIVE AND CHECKSUM
# ==============================================================================
log "2. Packaging artifacts from dist/ into release/"

cd "$DIST_DIR"

for asset in *; do
  [ -f "$asset" ] || continue
  log "Processing: $asset"
  archive_name="${asset}.tar.gz"
  tar -czf "$RELEASE_DIR/$archive_name" "$asset"
  ARCHIVES+=("$archive_name")
done

log "3. Generating SHA-256 checksums"
: >"$CHECKSUM_FILE"
cd "$RELEASE_DIR"
for archive in "${ARCHIVES[@]}"; do
  sha256sum "$archive" >>"$CHECKSUM_FILE"
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

# Linux
for arch in amd64 armv8 armv7 386; do
  name="libslipstream-client-linux-${arch}.tar.gz"
  label="$(echo "$arch" | sed 's/386/32-bit/;s/armv8/ARM64/;s/armv7/ARMv7/;s/amd64/AMD64/')"
  echo "| 🐧 **Linux** ${label} | $(get_link "$name" "📦 Download (.tar.gz)") |" >>"$NOTES_FILE"
done

# macOS
for arch in arm64 x86_64; do
  name="libslipstream-client-macos-${arch}.tar.gz"
  label="$(echo "$arch" | sed 's/arm64/Apple Silicon ARM64/;s/x86_64/Intel x86_64/')"
  echo "| 🍏 **macOS** ${label} | $(get_link "$name" "📦 Download (.tar.gz)") |" >>"$NOTES_FILE"
done

# Android
for arch in arm64 armv7 x86 amd64; do
  name="libslipstream-client-android-${arch}.tar.gz"
  label="$(echo "$arch" | sed 's/arm64/ARM64 (v8a)/;s/armv7/ARMv7/;s/x86/Intel x86/;s/amd64/AMD64/')"
  echo "| 🤖 **Android** ${label} | $(get_link "$name" "📦 Download (.tar.gz)") |" >>"$NOTES_FILE"
done

log "RELEASE MET SUCCESSFUL WITH TAG: $TAG_VERSION"
