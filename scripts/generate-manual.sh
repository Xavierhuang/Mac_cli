#!/usr/bin/env bash
# Generate roff(7) man pages for the `lingcode` CLI using the Swift Argument
# Parser GenerateManual plugin. Output lands in `Manuals/` and can be installed
# to /usr/local/share/man/man1 or shipped inside the LingCode.app bundle.
#
# Usage: ./LingCodeCLI/scripts/generate-manual.sh
#
# Requires:
#   - swift toolchain on PATH (Xcode or swift.org)
#   - swift-argument-parser >= 1.3 (already pinned in Package.swift)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$PKG_DIR/Manuals"

cd "$PKG_DIR"

mkdir -p "$OUT_DIR"

echo "Building lingcode (debug) so the plugin can introspect the command tree..."
swift build --product lingcode

echo "Generating man pages → $OUT_DIR"
swift package --allow-writing-to-package-directory \
  generate-manual lingcode \
  --output-directory "$OUT_DIR"

echo ""
echo "✓ Done. Top-level page: $OUT_DIR/lingcode.1"
echo ""
echo "Preview locally:    man -l $OUT_DIR/lingcode.1"
echo "Install for user:   cp $OUT_DIR/lingcode*.1 ~/.local/share/man/man1/"
echo "Install system:     sudo cp $OUT_DIR/lingcode*.1 /usr/local/share/man/man1/"
