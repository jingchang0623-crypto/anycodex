#!/usr/bin/env bash
# Vendor opencodex into the AnyCodex project for bundled distribution.
#
# Usage:
#   ./Scripts/vendor-opencodex.sh                    # bundle a bun runtime for this Mac's arch
#   OCX_BUN=none ./Scripts/vendor-opencodex.sh       # slim: rely on a system `bun` (brew install bun)
#   OCX_BUN=arm64 ./Scripts/vendor-opencodex.sh      # bundle the Apple Silicon runtime
#   OCX_BUN=x64 ./Scripts/vendor-opencodex.sh        # bundle the Intel runtime (cross-vendor)
#
# opencodex is a Bun application (Bun.serve, bun:sqlite, Bun.TOML) — node cannot
# run it. The slim variant therefore requires bun on the user's machine; it does
# not fall back to node.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PROJECT_DIR/vendor/opencodex"
OCX_BUN="${OCX_BUN:-host}"

echo "=== Vendoring opencodex (bun runtime: $OCX_BUN) ==="

if ! command -v ocx &>/dev/null; then
    echo "opencodex not found globally. Installing..."
    npm install -g @bitkyc08/opencodex
fi

OCX_PATH="$(command -v ocx)"
REAL_PATH="$(readlink -f "$OCX_PATH" 2>/dev/null || realpath "$OCX_PATH" 2>/dev/null || echo "$OCX_PATH")"
PACKAGE_DIR="$(dirname "$(dirname "$REAL_PATH")")"
echo "Package directory: $PACKAGE_DIR"

mkdir -p "$VENDOR_DIR"

# Launcher. Runs src/cli/index.ts directly rather than bin/ocx.mjs: that
# entrypoint insists on preparing its own bundled runtime and refuses to start
# when we ship without one. Internally it delegates to this same source entry.
cat > "$VENDOR_DIR/ocx" << 'LAUNCHER'
#!/bin/bash
# AnyCodex bundled opencodex launcher
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTRY="$SCRIPT_DIR/pkg/src/cli/index.ts"
BUNDLED="$SCRIPT_DIR/pkg/node_modules/bun/bin/bun.exe"

# Probe absolute paths before PATH: a GUI app launched by LaunchServices
# inherits launchd's PATH (/usr/bin:/bin:/usr/sbin:/sbin), which has neither
# Homebrew prefix, so `command -v bun` finds nothing even when bun is installed.
RUNTIME=""
if [ -x "$BUNDLED" ]; then
    RUNTIME="$BUNDLED"
else
    for candidate in \
        "$HOME/.bun/bin/bun" \
        /opt/homebrew/bin/bun \
        /usr/local/bin/bun \
        /opt/local/bin/bun
    do
        if [ -x "$candidate" ]; then RUNTIME="$candidate"; break; fi
    done
    if [ -z "$RUNTIME" ] && command -v bun >/dev/null 2>&1; then
        RUNTIME="$(command -v bun)"
    fi
fi

if [ -z "$RUNTIME" ]; then
    echo "Error: bun runtime not found." >&2
    echo "This is the slim AnyCodex build. Install bun with:  brew install bun" >&2
    echo "(or download the standard build, which bundles its own runtime)" >&2
    exit 1
fi

exec "$RUNTIME" "$ENTRY" "$@"
LAUNCHER
chmod +x "$VENDOR_DIR/ocx"

# Copy the package. `assets/` is README artwork (banner, architecture diagram,
# demo GIFs) that nothing reads at runtime, so it is left behind.
echo "Copying package..."
rm -rf "$VENDOR_DIR/pkg"
mkdir -p "$VENDOR_DIR/pkg"
for item in bin src gui node_modules package.json LICENSE; do
    [ -e "$PACKAGE_DIR/$item" ] && cp -R "$PACKAGE_DIR/$item" "$VENDOR_DIR/pkg/$item"
done

# Prune build-time-only payload from node_modules.
find "$VENDOR_DIR/pkg/node_modules" -type d \
    \( -name test -o -name tests -o -name docs -o -name example -o -name examples -o -name __tests__ \) \
    -exec rm -rf {} + 2>/dev/null || true
find "$VENDOR_DIR/pkg/node_modules" \
    \( -name "*.md" -o -name "*.map" -o -name "LICENSE*" \) -delete 2>/dev/null || true
# bunx is a package-runner CLI the proxy never invokes; it is a second 60 MB copy
# of the same binary.
rm -f "$VENDOR_DIR/pkg/node_modules/bun/bin/bunx.exe"

# Select the bundled bun runtime.
case "$OCX_BUN" in
    none)
        rm -rf "$VENDOR_DIR/pkg/node_modules/bun"
        echo "  ✓ Slim build — no bundled runtime (requires system bun)"
        ;;
    arm64|x64)
        BUN_NPM_PKG="@oven/bun-darwin-$([ "$OCX_BUN" = arm64 ] && echo aarch64 || echo x64)"
        BUN_VERSION="$(node -p "require('$PACKAGE_DIR/node_modules/bun/package.json').version" 2>/dev/null || echo latest)"
        echo "Fetching $BUN_NPM_PKG@$BUN_VERSION..."
        STAGE="$(mktemp -d)"
        (cd "$STAGE" && npm pack "$BUN_NPM_PKG@$BUN_VERSION" --silent >/dev/null 2>&1 && tar -xzf ./*.tgz)
        FETCHED="$(find "$STAGE/package" -type f -name "bun" -o -type f -name "bun.exe" 2>/dev/null | head -1)"
        if [ -n "$FETCHED" ]; then
            mkdir -p "$VENDOR_DIR/pkg/node_modules/bun/bin"
            cp "$FETCHED" "$VENDOR_DIR/pkg/node_modules/bun/bin/bun.exe"
            chmod +x "$VENDOR_DIR/pkg/node_modules/bun/bin/bun.exe"
            echo "  ✓ Bundled $OCX_BUN runtime ($(du -sh "$VENDOR_DIR/pkg/node_modules/bun/bin/bun.exe" | cut -f1))"
        else
            echo "  ✗ Could not fetch $BUN_NPM_PKG; keeping the host runtime" >&2
        fi
        rm -rf "$STAGE"
        ;;
    host)
        if [ -x "$VENDOR_DIR/pkg/node_modules/bun/bin/bun.exe" ]; then
            echo "  ✓ Bundled host runtime ($(du -sh "$VENDOR_DIR/pkg/node_modules/bun/bin/bun.exe" | cut -f1))"
        else
            echo "  ⚠ No bundled runtime found in the npm package" >&2
        fi
        ;;
    *)
        echo "Unknown OCX_BUN value: $OCX_BUN (expected host|none|arm64|x64)" >&2
        exit 1
        ;;
esac

# Drop the top-level runtime copy older builds shipped; the launcher now uses
# the package's own.
rm -f "$VENDOR_DIR/bun"

# Sweep dangling .bin symlinks left by the runtime pruning above — the packaging
# script's `xattr -cr` walk fails hard on a broken link.
find "$VENDOR_DIR/pkg/node_modules" -type l ! -exec test -e {} \; -delete 2>/dev/null || true

if [ -f "$PACKAGE_DIR/package.json" ]; then
    cp "$PACKAGE_DIR/package.json" "$VENDOR_DIR/package.json"
    echo "  ✓ opencodex version: $(node -p "require('$PACKAGE_DIR/package.json').version" 2>/dev/null || echo unknown)"
fi

echo ""
echo "=== Vendor complete ==="
echo "Total size: $(du -sh "$VENDOR_DIR" | cut -f1)"
