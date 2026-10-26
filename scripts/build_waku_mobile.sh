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
# Resolve to an ABSOLUTE path now. We `cd` into the go-waku workdir before
# writing the .so; a relative JNILIBS_DIR would otherwise resolve against
# /tmp/gowaku-build and the binary would land there instead of the workspace
# jniLibs (the build succeeds but the APK ships without it — exactly the
# "compiled OK yet NOT bundled" symptom we hit).
mkdir -p "$JNILIBS_DIR"
JNILIBS_DIR="$(cd "$JNILIBS_DIR" && pwd)"
# Pinned master commit, NOT the v0.9.0 release. v0.9.0 (2023) only speaks the
# legacy store protocol /vac/waku/store/2.0.0-beta4, which status.prod no
# longer mounts: every query answers "protocols not supported", so the offline
# mailbox is gone AND every publish fails its store confirmation (field,
# 2026-10-26). Master serves store v3 at GET /store/v3/messages; the Dart
# client tries v3 first and falls back to v1, so either binary still runs.
WAKU_VERSION="${WAKU_VERSION:-b0ddae443a58443fb634982d578055cb5c27af77}"
# Built instead when the pinned commit fails to compile, so a broken upstream
# costs store v3, not the whole Waku transport.
WAKU_FALLBACK_VERSION="${WAKU_FALLBACK_VERSION:-v0.9.0}"
WORKDIR="${WORKDIR:-/tmp/gowaku-build}"
ANDROID_TARGET="${ANDROID_TARGET:-23}"

echo "▶ jniLibs dir:        $JNILIBS_DIR"
echo "▶ go-waku version:    $WAKU_VERSION (fallback $WAKU_FALLBACK_VERSION)"
echo "▶ android target API: $ANDROID_TARGET"
echo "▶ workdir:            $WORKDIR"

# 1. Resolve the NDK (go-waku needs CGO for its crypto deps). We compile
#    for arm64-v8a (real phones) AND x86_64 (Waydroid + Android emulator),
#    same pattern as the bundled kubo binary. Without the x86_64 build,
#    Waydroid installs the APK but extracts no Waku binary and the daemon
#    silently stays off — exactly what surfaced as "bundled on Pocket Flip,
#    not bundled on Waydroid".
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME=$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/"*/ 2>/dev/null | sort -V | tail -1 || true)
  ANDROID_NDK_HOME=${ANDROID_NDK_HOME%/}
fi
if [ -z "$ANDROID_NDK_HOME" ]; then
  echo "✗ ANDROID_NDK_HOME not set and no NDK found — cannot cross-compile"
  exit 1
fi
echo "▶ NDK: $ANDROID_NDK_HOME"

# 2. A private Go toolchain per go-waku version, leaving the rest of CI on
#    its own Go. v0.9.0 pins quic-go v0.36.4, whose build guard refuses
#    Go >= 1.21; master needs Go 1.23.
fetch_go() {
  local pin="$1" root="/tmp/go-$1"
  if [ ! -x "$root/bin/go" ]; then
    echo "▶ fetching Go $pin toolchain for the go-waku build…" >&2
    curl -fsSL "https://go.dev/dl/go${pin}.linux-amd64.tar.gz" -o "/tmp/go-pin-$pin.tgz" || return 1
    rm -rf "$root" && mkdir -p "$root"
    tar -C "$root" --strip-components=1 -xzf "/tmp/go-pin-$pin.tgz" || return 1
  fi
  echo "$root/bin/go"
}

# 3. Cross-compile cmd/waku as a PIE executable for each target ABI.
#  - gowaku_no_rln: skip RLN (on-chain rate-limit nullifiers) — a private
#    messenger doesn't need zkSNARK spam protection, and RLN drags in zerokit
#    (Rust) which complicates the cross-build enormously.
#  - -buildmode=pie: Android requires position-independent executables.
#  - -ldflags "-s -w": strip symbol + DWARF tables to shrink the binary.
build_for_abi() {
  local abi="$1"        # jniLibs subdir name
  local goarch="$2"     # GOARCH value
  local cc_prefix="$3"  # NDK clang wrapper prefix
  local cc
  cc=$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" \
    -name "${cc_prefix}${ANDROID_TARGET}-clang" 2>/dev/null | head -1 || true)
  if [ -z "$cc" ]; then
    echo "⚠ NDK clang ${cc_prefix}${ANDROID_TARGET}-clang not found — skipping $abi"
    return 0
  fi
  local out_dir="$JNILIBS_DIR/$abi"
  local out_so="$out_dir/libgowaku.so"
  mkdir -p "$out_dir"
  echo "▶ building cmd/waku → $abi/libgowaku.so (CC=$cc)…"
  CGO_ENABLED=1 GOOS=android GOARCH="$goarch" CC="$cc" \
    "$GO_BIN" build \
      -buildmode=pie \
      -tags="gowaku_no_rln" \
      -ldflags="-s -w" \
      -o "$out_so" \
      ./cmd/waku || return 1
  echo "✓ wrote $out_so ($(du -h "$out_so" | cut -f1))"
  file "$out_so" || true
}

# 4. Fetch one exact go-waku revision (tag or commit SHA) and build both ABIs.
#    Every step returns explicitly: `set -e` does not apply inside the `if`
#    that decides whether to fall back.
build_version() {
  local version="$1" go_pin="$2"
  GO_BIN=$(fetch_go "$go_pin") || return 1
  export GOROOT="${GO_BIN%/bin/go}"
  export GOTOOLCHAIN=local
  echo "▶ go-waku $version with $("$GO_BIN" version)"
  rm -rf "$WORKDIR" && git init -q "$WORKDIR" || return 1
  cd "$WORKDIR" || return 1
  git fetch -q --depth=1 https://github.com/waku-org/go-waku.git "$version" || return 1
  git checkout -q FETCH_HEAD || return 1
  "$GO_BIN" mod download || return 1
  build_for_abi arm64-v8a arm64 aarch64-linux-android || return 1
  build_for_abi x86_64    amd64 x86_64-linux-android || return 1
}

if ! build_version "$WAKU_VERSION" "${GO_PIN:-1.23.11}"; then
  echo "⚠ go-waku $WAKU_VERSION failed to build — falling back to $WAKU_FALLBACK_VERSION (legacy store only)"
  rm -f "$JNILIBS_DIR"/*/libgowaku.so
  build_version "$WAKU_FALLBACK_VERSION" "${GO_PIN_FALLBACK:-1.20.14}"
fi
