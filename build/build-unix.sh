#!/bin/sh
# build-unix.sh — assemble the per-platform Linux/macOS tarball.
#
# Run ON the target platform (or in a GitHub Actions runner for that platform),
# because the dsh package contains platform-specific native modules that must be
# installed there.
#
# Usage:
#   ./build-unix.sh <dsh-package-dir> <node-binary> <os> <arch> <version> <outdir>
#
#   <dsh-package-dir>  directory of an installed @deepseek-ai/dsh package
#                      (contains lib/, config/, node_modules/, package.json)
#   <node-binary>      path to the node executable for this platform
#   <os>               linux | darwin
#   <arch>             x64 | arm64
#   <version>          e.g. 0.1.0-rc.8
#   <outdir>           where the .tar.gz is written
set -e

DSH_PKG="$1"
NODE_BIN="$2"
OS="$3"
ARCH="$4"
VERSION="$5"
OUTDIR="$6"

if [ -z "$DSH_PKG" ] || [ -z "$NODE_BIN" ] || [ -z "$OS" ] || [ -z "$ARCH" ] || [ -z "$VERSION" ] || [ -z "$OUTDIR" ]; then
    echo "usage: $0 <dsh-package-dir> <node-binary> <os> <arch> <version> <outdir>" >&2
    exit 2
fi

[ -d "$DSH_PKG" ] || { echo "dsh package dir not found: $DSH_PKG" >&2; exit 1; }
[ -x "$NODE_BIN" ] || { echo "node binary not found/executable: $NODE_BIN" >&2; exit 1; }
mkdir -p "$OUTDIR"

name="dsh-portable-${VERSION}-${OS}-${ARCH}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# Layout: dsh (launcher), node (binary), dsh-pkg/ (package).
cp -R "$DSH_PKG" "$stage/dsh-pkg"
cp "$NODE_BIN" "$stage/node"
chmod +x "$stage/node"
cp "$(dirname "$0")/launcher.sh" "$stage/dsh"
chmod +x "$stage/dsh"

tar -C "$stage" -czf "$OUTDIR/$name.tar.gz" dsh node dsh-pkg
echo "built: $OUTDIR/$name.tar.gz"
