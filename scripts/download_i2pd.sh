#!/usr/bin/env bash
# Downloads i2pd (PurpleI2P) native libraries for Android and places them in
# jniLibs as libi2pd.so per ABI — mirror of scripts/download_kubo.sh.
#
# Source: the official i2pd-android APK from PurpleI2P. The APK is just a zip
# whose lib/<abi>/libi2pd.so entries are exactly what we need. Same approach
# Orbot users take when bundling Tor — extract from an upstream-signed APK
# instead of trusting random third-party builds.
#
# Usage:
#   chmod +x scripts/download_i2pd.sh
#   ./scripts/download_i2pd.sh             # all ABIs
#   ./scripts/download_i2pd.sh arm64-v8a   # single ABI
#
# After running, rebuild the APK:
#   flutter build apk --split-per-abi --release

set -euo pipefail

# Pin to a known-good i2pd-android release. Bump when upstream ships a new
# stable. Check https://github.com/PurpleI2P/i2pd-android/releases for the
# latest tag and the per-ABI APK names — historically the project ships
# arm64-v8a, armeabi-v7a, x86 and x86_64 splits.
I2PD_VERSION="2.55.0"
BASE_URL="https://github.com/PurpleI2P/i2pd-android/releases/download/${I2PD_VERSION}"
JNILIBS_DIR="android/app/src/main/jniLibs"

declare -A APK_MAP=(
  [arm64-v8a]="i2pd-${I2PD_VERSION}-arm64-v8a.apk"
  [armeabi-v7a]="i2pd-${I2PD_VERSION}-armeabi-v7a.apk"
  [x86_64]="i2pd-${I2PD_VERSION}-x86_64.apk"
  [x86]="i2pd-${I2PD_VERSION}-x86.apk"
)

extract_abi() {
  local abi="$1"
  local apk_file="${APK_MAP[$abi]}"
  local url="${BASE_URL}/${apk_file}"
  local tmp="/tmp/i2pd_${abi}.apk"
  local dest_dir="${JNILIBS_DIR}/${abi}"
  local dest="${dest_dir}/libi2pd.so"

  mkdir -p "$dest_dir"
  echo "→ ${abi}…"

  if ! curl --progress-bar -fL "$url" -o "$tmp"; then
    echo "  ✗ download failed: $url"
    echo "    (release ${I2PD_VERSION} may not ship this ABI — edit I2PD_VERSION or skip)"
    return 1
  fi

  # APK is a zip; pull out only the libi2pd.so for our ABI, dropping the
  # internal directory structure so the file lands at jniLibs/<abi>/libi2pd.so.
  if ! unzip -j -o "$tmp" "lib/${abi}/libi2pd.so" -d "$dest_dir" >/dev/null 2>&1; then
    # Some i2pd-android builds bundle the executable as bin/i2pd inside
    # assets/ instead of lib/. Try that fallback before giving up.
    if ! unzip -j -o "$tmp" "assets/i2pd" -d "$dest_dir" >/dev/null 2>&1; then
      echo "  ✗ could not find libi2pd.so or assets/i2pd inside the APK"
      rm -f "$tmp"
      return 1
    fi
    mv "${dest_dir}/i2pd" "$dest"
  fi
  rm -f "$tmp"
  chmod +x "$dest"
  local size
  size=$(du -sh "$dest" | cut -f1)
  echo "  ✓ ${dest} (${size})"
}

if [[ $# -gt 0 ]]; then
  ABIS=("$@")
else
  ABIS=("arm64-v8a" "x86_64")
fi

cd "$(dirname "$0")/.."

echo "Downloading i2pd ${I2PD_VERSION} binaries…"
echo ""

FAILED=()
for abi in "${ABIS[@]}"; do
  if [[ -z "${APK_MAP[$abi]+_}" ]]; then
    echo "Unknown ABI: $abi  (valid: ${!APK_MAP[*]})"
    exit 1
  fi
  if ! extract_abi "$abi"; then
    FAILED+=("$abi")
  fi
done

echo ""
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "WARNING: failed to fetch ABIs: ${FAILED[*]}"
  echo ""
  echo "If the URLs returned 404, check the release page for the correct asset names:"
  echo "  https://github.com/PurpleI2P/i2pd-android/releases/tag/${I2PD_VERSION}"
  echo ""
  echo "If the project no longer ships standalone APKs per ABI, build i2pd"
  echo "yourself with the Android NDK:"
  echo "  git clone https://github.com/PurpleI2P/i2pd"
  echo "  cd i2pd && make HOST=android-arm64  # or android-arm / android-x86_64"
  echo "  cp i2pd ../${JNILIBS_DIR}/<abi>/libi2pd.so"
  exit 1
fi

echo "Done. Build the APK with ABI splits:"
echo "  flutter build apk --split-per-abi --release"
echo ""
echo "Or a universal APK (includes all ABIs, larger):"
echo "  flutter build apk --release"
