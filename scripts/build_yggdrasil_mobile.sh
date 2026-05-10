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
# Pin to a 2024 snapshot — the May-2026 release of x/mobile reorganised the
# bind/ subpackage and gobind fails to import it ("no Go package in
# golang.org/x/mobile/bind"). The 0e9ed... pseudo-version is the last known
# release where contrib/mobile of yggdrasil-go binds cleanly.
GOMOBILE_VERSION="${GOMOBILE_VERSION:-v0.0.0-20240910153849-0e9ed3da6e8e}"
export PATH="$(go env GOPATH)/bin:$PATH"
echo "▶ installing gomobile $GOMOBILE_VERSION…"
go install "golang.org/x/mobile/cmd/gomobile@$GOMOBILE_VERSION"
go install "golang.org/x/mobile/cmd/gobind@$GOMOBILE_VERSION"

# 2. gomobile init wires up the NDK toolchain
gomobile init

# 3. Clone yggdrasil-go (shallow)
rm -rf "$WORKDIR"
git clone --depth=1 --branch "$YGG_VERSION" \
  https://github.com/yggdrasil-network/yggdrasil-go.git "$WORKDIR"

cd "$WORKDIR"
go mod download

# gobind needs `golang.org/x/mobile/bind` resolvable from the target module.
# Yggdrasil-go doesn't declare it; pin to the same version as gomobile so
# they agree on the bind/ layout.
go get "golang.org/x/mobile@$GOMOBILE_VERSION"
go mod tidy

# 4. Bind. The contrib/mobile package exposes the Yggdrasil type used by
# YggDroid; same API works for any Android app that wants in-process routing.
gomobile bind \
  -target=android/arm64,android/arm,android/amd64 \
  -androidapi 21 \
  -javapkg=mobile \
  -o "$OUT" \
  ./contrib/mobile

echo "✓ wrote $OUT ($(du -h "$OUT" | cut -f1))"
