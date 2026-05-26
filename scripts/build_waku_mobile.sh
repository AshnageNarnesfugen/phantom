#!/usr/bin/env bash
# Build go-waku as an Android .aar via gomobile.
# Output: $1 (defaults to android/app/libs/gowaku.aar)
#
# The .aar includes the native Waku node with relay + store + lightpush
# protocols — enough for asynchronous P2P messaging on mobile.
#
# Prerequisites in CI / local:
#   - Go 1.22+
#   - Android SDK + NDK (ANDROID_HOME / ANDROID_NDK_HOME exported)
#   - JDK 17+
#
# Usage:
#   ./scripts/build_waku_mobile.sh [output.aar]
set -euo pipefail

OUT="${1:-$(pwd)/android/app/libs/gowaku.aar}"
mkdir -p "$(dirname "$OUT")"

WAKU_VERSION="${WAKU_VERSION:-v0.9.0}"
WORKDIR="${WORKDIR:-/tmp/gowaku-build}"
ANDROID_TARGET="${ANDROID_TARGET:-23}"

echo "▶ output: $OUT"
echo "▶ go-waku version: $WAKU_VERSION"
echo "▶ android target API: $ANDROID_TARGET"
echo "▶ workdir: $WORKDIR"

# 1. Install gomobile + gobind
# Pin to the same snapshot as the yggdrasil build so we don't fight
# different x/mobile layouts within the same CI run.
GOMOBILE_VERSION="${GOMOBILE_VERSION:-v0.0.0-20240910153849-0e9ed3da6e8e}"
export PATH="$(go env GOPATH)/bin:$PATH"
echo "▶ installing gomobile $GOMOBILE_VERSION…"
go install "golang.org/x/mobile/cmd/gomobile@$GOMOBILE_VERSION"
go install "golang.org/x/mobile/cmd/gobind@$GOMOBILE_VERSION"

# 2. gomobile init wires up the NDK toolchain
gomobile init

# 3. Clone go-waku (shallow)
rm -rf "$WORKDIR"
git clone --depth=1 --branch "$WAKU_VERSION" \
  https://github.com/waku-org/go-waku.git "$WORKDIR"

cd "$WORKDIR"
go mod download

# Add x/mobile dependency (same version as gomobile)
go get "golang.org/x/mobile@$GOMOBILE_VERSION"
go mod tidy

# 4. Build the Android .aar via gomobile bind
# - gowaku_no_rln: skip RLN (rate-limiting nullifiers) — we don't need
#   on-chain spam protection for a private messenger.
# - -ldflags="-s -w": strip debug info to reduce binary size.
# - target android/arm64 + android/amd64 to cover real devices + emulators.
echo "▶ building gowaku.aar (this takes a few minutes)…"
CGO=1 gomobile bind \
  -v \
  -target=android/arm64,android/amd64 \
  -androidapi="$ANDROID_TARGET" \
  -ldflags="-s -w" \
  -tags="gowaku_no_rln" \
  -o "$OUT" \
  ./library/mobile

echo "✓ wrote $OUT ($(du -h "$OUT" | cut -f1))"

# 5. Also produce a standalone c-shared .so for arm64 as a fallback.
# Some Flutter integration patterns prefer loading the .so directly via
# FFI instead of going through the .aar Java bindings.
SO_DIR="${SO_DIR:-$(dirname "$OUT")/../src/main/jniLibs}"
echo "▶ building libgowaku.so (arm64) for jniLibs fallback…"

mkdir -p "$SO_DIR/arm64-v8a"

# Resolve the NDK C compiler for arm64 cross-compilation
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME/ndk/"*/ 2>/dev/null | sort -V | tail -1 || true)
  ANDROID_NDK_HOME=${ANDROID_NDK_HOME%/}
fi

if [ -n "$ANDROID_NDK_HOME" ]; then
  CC_ARM64=$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" \
    -name "aarch64-linux-android${ANDROID_TARGET}-clang" 2>/dev/null | head -1 || true)

  if [ -n "$CC_ARM64" ]; then
    CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC="$CC_ARM64" \
      go build \
        -buildmode=c-shared \
        -tags="gowaku_no_rln" \
        -ldflags="-s -w" \
        -o "$SO_DIR/arm64-v8a/libgowaku.so" \
        ./library/c/

    echo "✓ wrote $SO_DIR/arm64-v8a/libgowaku.so ($(du -h "$SO_DIR/arm64-v8a/libgowaku.so" | cut -f1))"
  else
    echo "⚠ NDK clang not found for arm64 — skipping .so build"
  fi
else
  echo "⚠ ANDROID_NDK_HOME not set — skipping .so build"
fi
