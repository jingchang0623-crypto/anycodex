#!/bin/bash
# Vendor opencodex into the OpenAgent project for bundled distribution.
# Usage: ./Scripts/vendor-opencodex.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PROJECT_DIR/vendor/opencodex"

echo "=== Vendoring opencodex ==="

# Check if ocx is installed
if ! command -v ocx &>/dev/null; then
    echo "opencodex not found globally. Installing..."
    npm install -g @bitkyc08/opencodex
fi

OCX_PATH="$(which ocx)"
echo "Found ocx at: $OCX_PATH"

# Resolve the actual package location
REAL_PATH="$(readlink -f "$OCX_PATH" 2>/dev/null || realpath "$OCX_PATH" 2>/dev/null || echo "$OCX_PATH")"
PACKAGE_DIR="$(dirname "$(dirname "$REAL_PATH")")"

echo "Package directory: $PACKAGE_DIR"

# Create vendor structure
mkdir -p "$VENDOR_DIR"

# Copy the launcher script
cat > "$VENDOR_DIR/ocx" << 'LAUNCHER'
#!/bin/bash
# OpenAgent bundled opencodex launcher
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTRY="$SCRIPT_DIR/pkg/bin/ocx.mjs"

# Use bundled bun if available, otherwise system node/bun
if [ -x "$SCRIPT_DIR/bun" ]; then
    exec "$SCRIPT_DIR/bun" "$ENTRY" "$@"
elif command -v node &>/dev/null; then
    exec node "$ENTRY" "$@"
elif command -v bun &>/dev/null; then
    exec bun "$ENTRY" "$@"
else
    echo "Error: No JavaScript runtime found (need bun or node)" >&2
    exit 1
fi
LAUNCHER
chmod +x "$VENDOR_DIR/ocx"

# Copy the full package (entrypoint is pkg/bin/ocx.mjs; needs src + node_modules)
echo "Copying package..."
rm -rf "$VENDOR_DIR/pkg"
mkdir -p "$VENDOR_DIR/pkg"
for item in bin src gui assets node_modules package.json LICENSE; do
    [ -e "$PACKAGE_DIR/$item" ] && cp -R "$PACKAGE_DIR/$item" "$VENDOR_DIR/pkg/$item"
done
echo "  ✓ Copied $(du -sh "$VENDOR_DIR/pkg" | cut -f1)"

# Copy package.json for version tracking
if [ -f "$PACKAGE_DIR/package.json" ]; then
    cp "$PACKAGE_DIR/package.json" "$VENDOR_DIR/package.json"
    VERSION=$(grep '"version"' "$PACKAGE_DIR/package.json" | head -1 | sed 's/.*: "\(.*\)".*/\1/')
    echo "  ✓ opencodex version: $VERSION"
fi

# Try to bundle bun runtime (optional, ~50MB)
BUN_PATH="$(which bun 2>/dev/null || echo "")"
if [ -n "$BUN_PATH" ] && [ ! -f "$VENDOR_DIR/bun" ]; then
    echo "Bundling bun runtime..."
    cp "$BUN_PATH" "$VENDOR_DIR/bun"
    echo "  ✓ Bundled bun ($(du -sh "$VENDOR_DIR/bun" | cut -f1))"
else
    echo "  ℹ Skipping bun bundling (will use system runtime)"
fi

echo ""
echo "=== Vendor complete ==="
echo "Contents of $VENDOR_DIR:"
ls -la "$VENDOR_DIR"
echo ""
echo "Total size: $(du -sh "$VENDOR_DIR" | cut -f1)"
