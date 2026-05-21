#!/usr/bin/env bash
# Downloads i2pd (PurpleI2P) Android binaries and places them in jniLibs as
# libi2pd.so per ABI — mirror of scripts/download_kubo.sh.
#
# Source: the official `i2pd_<ver>_android_binary.zip` artifact from
# PurpleI2P/i2pd-android releases. The zip contains real standalone ELF
# executables (i2pd-aarch64, i2pd-x86_64, i2pd-armv7l, i2pd-x86) built with
# NDK r23c for Android 21+. We rename the per-ABI executable to libi2pd.so
# so Android's installer auto-extracts it to nativeLibraryDir alongside our
# Kubo binary.
#
# Usage:
#   chmod +x scripts/download_i2pd.sh
#   ./scripts/download_i2pd.sh             # all ABIs
#   ./scripts/download_i2pd.sh arm64-v8a   # single ABI
#
# After running, build the APK:
#   flutter build apk --split-per-abi --release

set -euo pipefail

# Pin to a known-good release. Bump when upstream ships a new stable.
# Check https://github.com/PurpleI2P/i2pd-android/releases for the latest.
I2PD_VERSION="2.60.0"
ARCHIVE_URL="https://github.com/PurpleI2P/i2pd-android/releases/download/${I2PD_VERSION}/i2pd_${I2PD_VERSION}_android_binary.zip"
JNILIBS_DIR="android/app/src/main/jniLibs"

# Map Android ABI → the executable name inside the zip.
declare -A BIN_MAP=(
  [arm64-v8a]="i2pd-aarch64"
  [armeabi-v7a]="i2pd-armv7l"
  [x86_64]="i2pd-x86_64"
  [x86]="i2pd-x86"
)

cd "$(dirname "$0")/.."

if [[ $# -gt 0 ]]; then
  ABIS=("$@")
else
  ABIS=("arm64-v8a" "x86_64")
fi

for abi in "${ABIS[@]}"; do
  if [[ -z "${BIN_MAP[$abi]+_}" ]]; then
    echo "Unknown ABI: $abi  (valid: ${!BIN_MAP[*]})"
    exit 1
  fi
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading i2pd ${I2PD_VERSION} (${ARCHIVE_URL##*/})…"
if ! curl --progress-bar -fL "$ARCHIVE_URL" -o "$TMP/i2pd.zip"; then
  echo ""
  echo "✗ download failed: $ARCHIVE_URL"
  echo "  Check the release page for the current archive name:"
  echo "    https://github.com/PurpleI2P/i2pd-android/releases/tag/${I2PD_VERSION}"
  echo "  If upstream stopped publishing this archive, build i2pd yourself:"
  echo "    git clone https://github.com/PurpleI2P/i2pd"
  echo "    cd i2pd && make HOST=android-arm64"
  echo "    cp i2pd ../${JNILIBS_DIR}/<abi>/libi2pd.so"
  exit 1
fi

echo ""
for abi in "${ABIS[@]}"; do
  bin_name="${BIN_MAP[$abi]}"
  dest_dir="${JNILIBS_DIR}/${abi}"
  dest="${dest_dir}/libi2pd.so"

  echo "→ ${abi} (${bin_name})…"
  mkdir -p "$dest_dir"
  if ! unzip -j -o "$TMP/i2pd.zip" "$bin_name" -d "$TMP" >/dev/null; then
    echo "  ✗ ${bin_name} not present in archive"
    exit 1
  fi
  mv "$TMP/$bin_name" "$dest"
  chmod +x "$dest"
  size=$(du -sh "$dest" | cut -f1)
  echo "  ✓ ${dest} (${size})"
done

echo ""
echo "Done. Build the APK with ABI splits:"
echo "  flutter build apk --split-per-abi --release"
echo ""
echo "Or a universal APK (includes all ABIs, larger):"
echo "  flutter build apk --release"
