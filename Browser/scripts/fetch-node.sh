#!/bin/zsh
# Downloads the official Node.js runtime that ships inside keydillo.app to run the browser tool, and checks it
# against nodejs.org's published SHA-256. Homebrew's node can't be bundled: it links libraries from /opt/homebrew.
set -euo pipefail
VERSION="${NODE_VERSION:-v22.16.0}"
ARCH="${NODE_ARCH:-arm64}"
cd "$(dirname "$0")/.."
mkdir -p runtime
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
NAME="node-$VERSION-darwin-$ARCH"
curl -fsSL "https://nodejs.org/dist/$VERSION/$NAME.tar.gz" -o "$TMP/$NAME.tar.gz"
curl -fsSL "https://nodejs.org/dist/$VERSION/SHASUMS256.txt" -o "$TMP/SHASUMS256.txt"
(cd "$TMP" && grep " $NAME.tar.gz\$" SHASUMS256.txt | shasum -a 256 -c -)
tar -xzf "$TMP/$NAME.tar.gz" -C "$TMP" "$NAME/bin/node" "$NAME/LICENSE"
cp "$TMP/$NAME/bin/node" runtime/node
cp "$TMP/$NAME/LICENSE" runtime/NODE-LICENSE
chmod 755 runtime/node
echo "runtime/node: $(runtime/node --version) ($ARCH)"
