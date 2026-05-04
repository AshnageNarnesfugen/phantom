#!/usr/bin/env bash
# Downloads Kubo (go-ipfs) binaries for Android and places them in jniLibs.
# Run this once before building the APK.
#
# Usage:
#   chmod +x scripts/download_kubo.sh
#   ./scripts/download_kubo.sh            # all ABIs
#   ./scripts/download_kubo.sh arm64-v8a  # single ABI

set -euo pipefail

KUBO_VERSION="v0.41.0"
BASE_URL="https://github.com/ipfs/kubo/releases/download/${KUBO_VERSION}"
JNILIBS_DIR="android/app/src/main/jniLibs"

# Map Android ABI → Kubo archive architecture name
# armeabi-v7a (linux-arm 32-bit) dropped by Kubo since v0.36; excluded.
declare -A ARCH_MAP=(
  [arm64-v8a]="arm64"
  [x86_64]="amd64"
)

download_abi() {
  local abi="$1"
  local arch="${ARCH_MAP[$abi]}"
  local dest="${JNILIBS_DIR}/${abi}/libkubo.so"
  local tmp="/tmp/kubo_${abi}.tar.gz"
  local url="${BASE_URL}/kubo_${KUBO_VERSION}_linux-${arch}.tar.gz"

  echo "→ ${abi} (linux-${arch})…"
  curl --progress-bar -fL "$url" -o "$tmp"
  # Extract only the 'kubo/ipfs' entry from the archive, rename to libkubo.so
  tar -xzf "$tmp" -O "kubo/ipfs" > "$dest"
  rm -f "$tmp"
  chmod +x "$dest"
  local size
  size=$(du -sh "$dest" | cut -f1)
  echo "  ✓ ${dest} (${size})"
}

# Determine which ABIs to build
if [[ $# -gt 0 ]]; then
  ABIS=("$@")
else
  ABIS=("arm64-v8a" "x86_64")
fi

cd "$(dirname "$0")/.."

echo "Downloading Kubo ${KUBO_VERSION} binaries…"
echo ""

for abi in "${ABIS[@]}"; do
  if [[ -z "${ARCH_MAP[$abi]+_}" ]]; then
    echo "Unknown ABI: $abi  (valid: arm64-v8a, armeabi-v7a, x86_64)"
    exit 1
  fi
  download_abi "$abi"
done

echo ""
echo "Done. Build the APK with ABI splits:"
echo "  flutter build apk --split-per-abi --release"
echo ""
echo "Or a universal APK (includes all ABIs, larger):"
echo "  flutter build apk --release"
