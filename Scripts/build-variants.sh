#!/usr/bin/env bash
# Build (and optionally notarize) the AnyCodex distribution matrix.
#
#   arch      arm64 (Apple Silicon) | x64 (Intel)
#   runtime   bundled bun (~161 MB) | slim, requires `brew install bun` (~101 MB)
#
# Usage:
#   ./Scripts/build-variants.sh                 # build all four, ad-hoc signed
#   ./Scripts/build-variants.sh --notarize      # Developer ID sign + notarize each
#   VARIANTS="arm64-slim" ./Scripts/build-variants.sh
#
# Notarization needs the same env the release script does:
#   APP_IDENTITY, APP_TEAM_ID, APP_STORE_CONNECT_API_KEY_FILE,
#   APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"
source "$ROOT/version.env"

NOTARIZE=false
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=true

OUT_DIR="$ROOT/dist"
mkdir -p "$OUT_DIR"

VARIANTS="${VARIANTS:-arm64-full arm64-slim x64-full x64-slim}"

for variant in $VARIANTS; do
    arch="${variant%%-*}"
    runtime="${variant##*-}"
    swift_arch="$([[ "$arch" == arm64 ]] && echo arm64 || echo x86_64)"
    bun_mode="$([[ "$runtime" == full ]] && echo "$arch" || echo none)"

    echo ""
    echo "═══ Building $variant (swift=$swift_arch, bun=$bun_mode) ═══"
    OCX_BUN="$bun_mode" "$SCRIPT_DIR/vendor-opencodex.sh" >/dev/null
    rm -rf "$ROOT/AnyCodex.app"

    if [[ "$NOTARIZE" == true ]]; then
        ARCHES="$swift_arch" "$SCRIPT_DIR/sign-and-notarize.sh" >/dev/null
    else
        ARCHES="$swift_arch" "$SCRIPT_DIR/package_app.sh" release >/dev/null
    fi

    zip_name="AnyCodex-${MARKETING_VERSION}-${arch}$([[ "$runtime" == slim ]] && echo "-slim" || echo "").zip"
    rm -f "$OUT_DIR/$zip_name"
    /usr/bin/ditto --norsrc -c -k --keepParent "$ROOT/AnyCodex.app" "$OUT_DIR/$zip_name"
    echo "  ✓ $zip_name ($(du -h "$OUT_DIR/$zip_name" | cut -f1), app $(du -sh "$ROOT/AnyCodex.app" | cut -f1))"
done

echo ""
echo "=== Variants in $OUT_DIR ==="
ls -lh "$OUT_DIR"/*.zip | awk '{print "  " $9 "  " $5}'
