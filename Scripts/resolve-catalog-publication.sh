#!/usr/bin/env bash
set -euo pipefail

# Decide whether to update discovery after verifying the current catalog.
# A scheduled historical release is still published, but does not move the
# discovery catalog backwards. Manual requests retain the explicit guard.
previous="${1:?previous catalog payload required}"
candidate="${2:?candidate catalog required}"
event="${3:?event required}"
allow_downgrade="${4:-false}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$previous" ] || { echo "Verified previous catalog payload is missing: $previous" >&2; exit 1; }
[ -f "$candidate" ] || { echo "Candidate catalog is missing: $candidate" >&2; exit 1; }

skip=0
allow=0
[ "$event" != schedule ] || skip=1
[ "$allow_downgrade" != true ] || allow=1

if ALLOW_CATALOG_DOWNGRADE="$allow" SKIP_CATALOG_DOWNGRADE="$skip" \
    "$script_dir/check-catalog-precedent.sh" "$previous" "$candidate" >&2; then
    echo true
else
    status=$?
    if [ "$status" -eq 3 ] && [ "$event" = schedule ]; then
        echo false
    else
        exit "$status"
    fi
fi
