#!/usr/bin/env bash
# Register models a provider serves but does not advertise in /v1/models.
#
# opencodex treats provider model discovery as authoritative: models listed in
# provider config but missing from the live /v1/models response get pruned from
# the catalog on every sync. Custom models (this script) are a separate,
# discovery-independent path — the supported way to expose such models.
#
# Usage:
#   ./Scripts/register-custom-models.sh <provider> <model> [model...]
#   ./Scripts/register-custom-models.sh --list
#
# Example — a relay that serves OpenAI models but only advertises others:
#   ./Scripts/register-custom-models.sh myrelay gpt-5.6-sol gpt-5.5 gpt-5.4
#
# Re-running is safe: models already registered are skipped.
# Options: CONTEXT_WINDOW (default 400000), MODALITIES (default text,image).
set -euo pipefail

CONTEXT_WINDOW="${CONTEXT_WINDOW:-400000}"
MODALITIES="${MODALITIES:-text,image}"

find_ocx() {
    local candidates=(
        "/Applications/AnyCodex.app/Contents/Resources/opencodex/ocx"
        "$(cd "$(dirname "$0")/.." && pwd)/vendor/opencodex/ocx"
        "$(command -v ocx 2>/dev/null || true)"
    )
    for candidate in "${candidates[@]}"; do
        [[ -n "$candidate" && -x "$candidate" ]] && { echo "$candidate"; return 0; }
    done
    echo "ERROR: ocx not found. Install AnyCodex, run Scripts/vendor-opencodex.sh," >&2
    echo "       or: npm install -g @bitkyc08/opencodex" >&2
    return 1
}

OCX=$(find_ocx)

if [[ "${1:-}" == "--list" ]]; then
    exec "$OCX" models list-custom
fi

if [[ $# -lt 2 ]]; then
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

PROVIDER="$1"
shift

EXISTING=$("$OCX" models list-custom 2>/dev/null || true)
ADDED=0
SKIPPED=0

for model in "$@"; do
    # list-custom groups by provider and prints bare model ids in a column.
    if grep -qE "(^|[[:space:]])${model}([[:space:]]|$)" <<<"$EXISTING"; then
        echo "  = $PROVIDER/$model (already registered)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if "$OCX" models add "$PROVIDER" "$model" \
        --context-window "$CONTEXT_WINDOW" \
        --modalities "$MODALITIES" >/dev/null 2>&1
    then
        echo "  + $PROVIDER/$model"
        ADDED=$((ADDED + 1))
    else
        echo "  ! $PROVIDER/$model failed to register" >&2
    fi
done

echo "Registered $ADDED, skipped $SKIPPED."

if [[ $ADDED -gt 0 ]]; then
    echo "Syncing Codex catalog..."
    "$OCX" sync >/dev/null 2>&1 || true
    "$OCX" sync-cache >/dev/null 2>&1 || true
    echo "Done. Restart the Codex app to see the new models in its picker."
fi
