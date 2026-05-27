#!/usr/bin/env bash
# Build the go-waku CLI as an Android arm64 PIE executable, shipped as
# `libgowaku.so` in jniLibs.
#
# Why an executable (not a .aar / c-shared lib):
#   WakuDaemon (lib/core/waku_daemon.dart) spawns the binary as a *process*
#   with CLI flags (--relay --store --rest --rest-port=0 …) and talks to it
#   over its local REST API, exactly like the bundled i2pd (libi2pd.so) and
#   Kubo (libkubo.so) daemons. A gomobile .aar (Java bindings) or a
#   `-buildmode=c-shared` library can't be Process.start()'d, so the previous
#   artifacts were unusable and Waku silently stayed off.
#
# Android packages everything matching jniLibs/<abi>/lib*.so and, with
# extractNativeLibs, unpacks it into the app's nativeLibraryDir — one of the
# few exec-permitted locations on modern Android. Naming the ELF `libgowaku.so`
# is what lets us ship a runnable daemon inside the APK.
#
# Prerequisites (CI / local):
#   - Go 1.22+
#   - Android NDK (ANDROID_NDK_HOME, or ANDROID_HOME with an ndk/ dir)
#
# Usage:
#   ./scripts/build_waku_mobile.sh [jniLibs_dir]
#   (defaults to android/app/src/main/jniLibs)
set -euo pipefail

JNILIBS_DIR="${1:-$(pwd)/android/app/src/main/jniLibs}"
WAKU_VERSION="${WAKU_VERSION:-v0.9.0}"
WORKDIR="${WORKDIR:-/tmp/gowaku-build}"
ANDROID_TARGET="${ANDROID_TARGET:-23}"

echo "▶ jniLibs dir:        $JNILIBS_DIR"
echo "▶ go-waku version:    $WAKU_VERSION"
echo "▶ android target API: $ANDROID_TARGET"
echo "▶ workdir:            $WORKDIR"

# 1. Resolve the NDK arm64 C compiler (go-waku needs CGO for its crypto deps).
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME=$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/"*/ 2>/dev/null | sort -V | tail -1 || true)
  ANDROID_NDK_HOME=${ANDROID_NDK_HOME%/}
fi
if [ -z "$ANDROID_NDK_HOME" ]; then
  echo "✗ ANDROID_NDK_HOME not set and no NDK found — cannot cross-compile"
  exit 1
fi
echo "▶ NDK: $ANDROID_NDK_HOME"

CC_ARM64=$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" \
  -name "aarch64-linux-android${ANDROID_TARGET}-clang" 2>/dev/null | head -1 || true)
if [ -z "$CC_ARM64" ]; then
  echo "✗ NDK clang aarch64-linux-android${ANDROID_TARGET}-clang not found"
  exit 1
fi
echo "▶ CC: $CC_ARM64"

# 2. Clone go-waku (shallow).
rm -rf "$WORKDIR"
git clone --depth=1 --branch "$WAKU_VERSION" \
  https://github.com/waku-org/go-waku.git "$WORKDIR"
cd "$WORKDIR"
go mod download

# 3. Cross-compile cmd/waku as a PIE executable.
#  - gowaku_no_rln: skip RLN (on-chain rate-limit nullifiers) — a private
#    messenger doesn't need zkSNARK spam protection, and RLN drags in zerokit
#    (Rust) which complicates the cross-build enormously.
#  - -buildmode=pie: Android requires position-independent executables.
#  - -ldflags "-s -w": strip symbol + DWARF tables to shrink the binary.
mkdir -p "$JNILIBS_DIR/arm64-v8a"
OUT_SO="$JNILIBS_DIR/arm64-v8a/libgowaku.so"

echo "▶ building cmd/waku → libgowaku.so (arm64, PIE) — this takes a few minutes…"
CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC="$CC_ARM64" \
  go build \
    -buildmode=pie \
    -tags="gowaku_no_rln" \
    -ldflags="-s -w" \
    -o "$OUT_SO" \
    ./cmd/waku

echo "✓ wrote $OUT_SO ($(du -h "$OUT_SO" | cut -f1))"
file "$OUT_SO" || true
