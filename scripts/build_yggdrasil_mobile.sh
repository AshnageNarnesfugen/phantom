#!/usr/bin/env bash
# Build yggdrasil-go as an Android .aar via gomobile.
# Output: $1 (defaults to android/app/libs/yggdrasil-mobile.aar)
#
# Prerequisites in CI / local:
#   - go 1.22+
#   - Android SDK + NDK (ANDROID_HOME / ANDROID_NDK_HOME exported)
#   - JDK 17+
#
# Usage:
#   ./scripts/build_yggdrasil_mobile.sh [output.aar]
set -euo pipefail

OUT="${1:-$(pwd)/android/app/libs/yggdrasil-mobile.aar}"
mkdir -p "$(dirname "$OUT")"

YGG_VERSION="${YGG_VERSION:-v0.5.12}"
WORKDIR="${WORKDIR:-/tmp/yggdrasil-build}"

echo "▶ output: $OUT"
echo "▶ yggdrasil-go version: $YGG_VERSION"
echo "▶ workdir: $WORKDIR"

# 1. Install gomobile + gobind into GOPATH (idempotent)
export PATH="$(go env GOPATH)/bin:$PATH"
if ! command -v gomobile &>/dev/null; then
  echo "▶ installing gomobile…"
  go install golang.org/x/mobile/cmd/gomobile@latest
  go install golang.org/x/mobile/cmd/gobind@latest
fi

# 2. gomobile init wires up the NDK toolchain
gomobile init

# 3. Clone yggdrasil-go (shallow)
rm -rf "$WORKDIR"
git clone --depth=1 --branch "$YGG_VERSION" \
  https://github.com/yggdrasil-network/yggdrasil-go.git "$WORKDIR"

cd "$WORKDIR"
go mod download

# 4. Bind. The contrib/mobile package exposes the Yggdrasil type used by
# YggDroid; same API works for any Android app that wants in-process routing.
gomobile bind \
  -target=android/arm64,android/arm,android/amd64 \
  -androidapi 21 \
  -javapkg=mobile \
  -o "$OUT" \
  ./contrib/mobile

echo "✓ wrote $OUT ($(du -h "$OUT" | cut -f1))"
