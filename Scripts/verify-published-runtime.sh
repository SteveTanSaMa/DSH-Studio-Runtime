#!/usr/bin/env bash
set -euo pipefail

# Verifies the Runtime catalog and its artifacts exactly as clients see them:
# download the published catalog, verify its signature with the project's trust
# anchor, then download every artifact the catalog advertises and check the
# published checksum, size and URL shape.
#
# It needs no secret, so it serves as the post-publish gate of the release
# pipeline and as a manual spot check of the live distribution.
#
# Usage: verify-published-runtime.sh [RUNTIME_VERSION] [PUBLIC_KEY_BASE64] [CATALOG_URL]

RUNTIME_VERSION="${1:-}"
PUBLIC_KEY_BASE64="${2:-${RUNTIME_CATALOG_PUBLIC_KEY:-}}"
REPOSITORY="${RUNTIME_DISTRIBUTION_REPOSITORY:-SteveTanSaMa/DSH-Studio-Runtime}"
EXPECTED_BASE_URL="https://github.com/$REPOSITORY/releases/download"
CATALOG_URL="${3:-$EXPECTED_BASE_URL/runtime-catalog/runtime-catalog.signed.json}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
    printf 'verify-published-runtime: %s\n' "$1" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || die "missing required command: curl"
command -v node >/dev/null 2>&1 || die "missing required command: node"
command -v shasum >/dev/null 2>&1 || die "missing required command: shasum"
[ -n "$PUBLIC_KEY_BASE64" ] || die "a base64 Ed25519 public key is required (second argument or RUNTIME_CATALOG_PUBLIC_KEY)"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-runtime-published.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

printf 'Downloading %s\n' "$CATALOG_URL"
curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 \
    "$CATALOG_URL" -o "$WORK_DIR/runtime-catalog.signed.json" || die "could not download the published catalog"

"$SCRIPT_DIR/verify-runtime-catalog.sh" \
    "$WORK_DIR/runtime-catalog.signed.json" \
    "$PUBLIC_KEY_BASE64" \
    "$WORK_DIR/payload.json" || die "the published catalog did not verify"

node -e '
const fs = require("fs");
const catalog = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
fs.writeFileSync(process.argv[2], catalog.runtimeVersion + "\n");
fs.writeFileSync(process.argv[3], catalog.releases.map((release) => {
  const artifact = release.artifact || {};
  return [release.architecture, artifact.url, artifact.sha256, artifact.size].join("\t");
}).join("\n") + "\n");
' "$WORK_DIR/payload.json" "$WORK_DIR/catalog-version.txt" "$WORK_DIR/artifacts.tsv" || die "could not read the signed catalog payload"

CATALOG_VERSION="$(cat "$WORK_DIR/catalog-version.txt")"
if [ -n "$RUNTIME_VERSION" ] && [ "$CATALOG_VERSION" != "$RUNTIME_VERSION" ]; then
    die "the published catalog offers $CATALOG_VERSION, expected $RUNTIME_VERSION"
fi

[ -s "$WORK_DIR/artifacts.tsv" ] || die "the published catalog lists no artifacts"

VERIFIED=0
while IFS=$'\t' read -r architecture url sha256 size; do
    [ -n "${architecture:-}" ] || continue
    expected_url="$EXPECTED_BASE_URL/runtime-$CATALOG_VERSION/dsh-runtime-$CATALOG_VERSION-$architecture.tar.gz"
    [ "$url" = "$expected_url" ] || die "the catalog URL for $architecture is not the one clients accept: $url"
    case "$sha256" in
        [0-9a-f][0-9a-f]*) ;;
        *) die "the catalog checksum for $architecture is not a hex digest: $sha256" ;;
    esac

    printf 'Downloading %s\n' "$url"
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 1800 \
        "$url" -o "$WORK_DIR/$architecture.tar.gz" || die "could not download the $architecture artifact"

    actual_sha256="$(shasum -a 256 "$WORK_DIR/$architecture.tar.gz" | awk '{print $1}')"
    [ "$actual_sha256" = "$sha256" ] || die \
        "the $architecture artifact does not match the published checksum (published $sha256, downloaded $actual_sha256)"
    actual_size="$(wc -c < "$WORK_DIR/$architecture.tar.gz" | tr -d '[:space:]')"
    if [ -n "${size:-}" ] && [ "$actual_size" != "$size" ]; then
        die "the $architecture artifact does not match the published size (published $size, downloaded $actual_size)"
    fi

    VERIFIED=$((VERIFIED + 1))
done < "$WORK_DIR/artifacts.tsv"

printf 'Published Runtime verified: %s (%s architectures)\n' "$CATALOG_VERSION" "$VERIFIED"
