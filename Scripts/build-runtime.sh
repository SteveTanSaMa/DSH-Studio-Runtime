#!/usr/bin/env bash
set -euo pipefail

# Builds an immutable Runtime artifact for one macOS architecture.
#
# npm is deliberately used only during this build step, never by the
# installed application.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die() {
    printf 'build-runtime: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

RUNTIME_VERSION="${RUNTIME_VERSION:-${1:-}}"
ARCHITECTURE="${ARCHITECTURE:-${2:-}}"
NODE_VERSION="${NODE_VERSION:-24.19.0}"
REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPOSITORY_ROOT/RuntimeArtifacts}"
ARTIFACT_BASE_URL="${RUNTIME_ARTIFACT_BASE_URL:-https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-${RUNTIME_VERSION}}"

[ -n "$RUNTIME_VERSION" ] || die "usage: RUNTIME_VERSION=0.2.0-rc.1 ARCHITECTURE=darwin-arm64 $0"

# The public Runtime version IS the upstream Harness version, nothing else. A
# repack of the same Harness version keeps the same name; the artifact is
# identified by its SHA-256, not by a build counter. Keep this pattern in sync
# with runtime-builder.yml and generate-runtime-catalog.sh.
RUNTIME_VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'
if [[ ! "$RUNTIME_VERSION" =~ $RUNTIME_VERSION_PATTERN ]]; then
    die "RUNTIME_VERSION must be the official Harness version, for example 0.2.0-rc.1 (got: $RUNTIME_VERSION)"
fi
# Point anyone still using the retired identity at what replaced it.
case "$RUNTIME_VERSION" in
    *-ver[0-9]*|*-r[0-9]*|*-rebuild-[0-9]*|*-revision-[0-9]*)
        die "RUNTIME_VERSION must not carry a build counter: one Harness version is one current Runtime, so drop the suffix from $RUNTIME_VERSION"
        ;;
esac

if [ -z "$ARCHITECTURE" ]; then
    case "$(uname -m)" in
        arm64) ARCHITECTURE="darwin-arm64" ;;
        x86_64) ARCHITECTURE="darwin-x64" ;;
        *) die "unsupported host architecture: $(uname -m)" ;;
    esac
fi

case "$ARCHITECTURE" in
    darwin-arm64) NODE_SUFFIX="arm64"; RUNTIME_PLATFORM="macos" ;;
    darwin-x64) NODE_SUFFIX="x64"; RUNTIME_PLATFORM="macos" ;;
    *) die "unsupported Runtime architecture: $ARCHITECTURE" ;;
esac

# npm is only ever invoked through the Node distribution downloaded below, so
# the host toolchain is limited to what the build itself needs.
require_command curl
require_command shasum
require_command tar
require_command gzip

# The current Harness dependency graph can exceed Node's default ~2 GiB V8
# heap during npm install. Keep the limit configurable for smaller runners,
# while giving CI enough headroom for the official Runtime build.
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=6144}"

WORK_DIR="${WORK_DIR:-}"
REMOVE_WORK_DIR=0
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-runtime-builder.XXXXXX")"
    REMOVE_WORK_DIR=1
else
    mkdir -p "$WORK_DIR"
fi

cleanup() {
    if [ "$REMOVE_WORK_DIR" -eq 1 ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

STAGE_DIR="$WORK_DIR/runtime"
NODE_ROOT="$STAGE_DIR/node/$ARCHITECTURE"
HARNESS_VERSION="${HARNESS_VERSION:-$RUNTIME_VERSION}"
PNPM_VERSION="${PNPM_VERSION:-}"
DATA_FORMAT_ID="${DSH_RUNTIME_DATA_FORMAT_ID:-}"
DATA_FORMAT_COMPATIBLE_WITH="${DSH_RUNTIME_DATA_FORMAT_COMPATIBLE_WITH:-}"
DATA_FORMAT_MIGRATION="${DSH_RUNTIME_DATA_FORMAT_MIGRATION:-}"
PLUGIN_MARKET_PACKAGE="${PLUGIN_MARKET_PACKAGE:-dshmarket}"
PLUGIN_MARKET_VERSION="${PLUGIN_MARKET_VERSION:-}"
# `PLUGIN_MARKET_VERSION=none` spells the explicit "publish no pin" decision the
# release workflow offers, so an operator never has to edit this script to ship a
# Runtime while the market is still catching up with a new Harness line.
if [ "$PLUGIN_MARKET_VERSION" = "none" ]; then
    PLUGIN_MARKET_VERSION=""
    DSH_RUNTIME_ALLOW_MISSING_PLUGIN_MARKET=1
fi

# Fail before downloading anything: the identity is known up front, and a typo
# in it must not cost a Node.js download first.
[ -n "$HARNESS_VERSION" ] || die "HARNESS_VERSION is required or derived from RUNTIME_VERSION"
[ "$HARNESS_VERSION" = "$RUNTIME_VERSION" ] || die \
    "HARNESS_VERSION ($HARNESS_VERSION) must equal RUNTIME_VERSION ($RUNTIME_VERSION): the Runtime version is the Harness version"
case "$HARNESS_VERSION" in
    *[!A-Za-z0-9._-]*) die "Harness version contains unsupported characters: $HARNESS_VERSION" ;;
esac

# A Runtime artifact is identified by its version alone, so every input that
# changes its bytes has to be pinned: resolving pnpm at build time would let two
# builds of the same Runtime version ship different contents.
if [ -z "$PNPM_VERSION" ] && [ "${DSH_RUNTIME_ALLOW_UNPINNED_PNPM:-0}" != "1" ]; then
    die "PNPM_VERSION is required: pin the packaged pnpm (for example PNPM_VERSION=11.22.0), or set DSH_RUNTIME_ALLOW_UNPINNED_PNPM=1 for a local build that is never released"
fi

mkdir -p "$STAGE_DIR"

NODE_ARCHIVE_NAME="node-v${NODE_VERSION}-darwin-${NODE_SUFFIX}.tar.gz"
NODE_BASE_URL="https://nodejs.org/dist/v${NODE_VERSION}"
NODE_ARCHIVE_URL="$NODE_BASE_URL/$NODE_ARCHIVE_NAME"
NODE_CHECKSUMS="$WORK_DIR/SHASUMS256.txt"
NODE_ARCHIVE="$WORK_DIR/$NODE_ARCHIVE_NAME"

printf 'Downloading Node.js %s for %s\n' "$NODE_VERSION" "$ARCHITECTURE"
curl -fsSL --connect-timeout 20 --max-time 900 --retry 3 "$NODE_BASE_URL/SHASUMS256.txt" -o "$NODE_CHECKSUMS"
EXPECTED_NODE_SHA256="$(awk -v name="$NODE_ARCHIVE_NAME" '$2 == name { print $1; exit }' "$NODE_CHECKSUMS")"
[ -n "$EXPECTED_NODE_SHA256" ] || die "Node archive is missing from the official checksum list"
curl -fsSL --connect-timeout 20 --max-time 900 --retry 3 "$NODE_ARCHIVE_URL" -o "$NODE_ARCHIVE"
ACTUAL_NODE_SHA256="$(shasum -a 256 "$NODE_ARCHIVE" | awk '{print $1}')"
[ "$ACTUAL_NODE_SHA256" = "$EXPECTED_NODE_SHA256" ] || die "Node archive checksum mismatch"

mkdir -p "$NODE_ROOT"
tar -xzf "$NODE_ARCHIVE" -C "$NODE_ROOT" --strip-components 1

NODE_EXECUTABLE="$NODE_ROOT/bin/node"
NPM_CLI="$NODE_ROOT/lib/node_modules/npm/bin/npm-cli.js"
[ -x "$NODE_EXECUTABLE" ] || die "downloaded Node executable is missing"
[ -f "$NPM_CLI" ] || die "downloaded Node npm CLI is missing"

resolve_latest() {
    local package_name="$1"
    "$NODE_EXECUTABLE" "$NPM_CLI" view "$package_name" version \
        --registry "$REGISTRY" 2>/dev/null | tr -d '[:space:]'
}

# Only reachable for explicitly unpinned local builds; the release pipeline
# always pins pnpm before it gets here.
if [ -z "$PNPM_VERSION" ]; then
    PNPM_VERSION="$(resolve_latest 'pnpm')"
    printf 'WARNING: pnpm is not pinned; resolved pnpm@%s from the registry. This build must not be published.\n' \
        "$PNPM_VERSION" >&2
fi
[ -n "$PNPM_VERSION" ] || die "could not resolve the pnpm version"
case "$PNPM_VERSION" in
    *[!A-Za-z0-9._-]*) die "pnpm version contains unsupported characters: $PNPM_VERSION" ;;
esac

HARNESS_ROOT="$STAGE_DIR/harness/$ARCHITECTURE/$HARNESS_VERSION"
mkdir -p "$HARNESS_ROOT"

"$NODE_EXECUTABLE" - "$HARNESS_ROOT/package.json" "$HARNESS_VERSION" "$PNPM_VERSION" <<'NODE'
const fs = require("fs");
const [path, harnessVersion, pnpmVersion] = process.argv.slice(2);
fs.writeFileSync(path, JSON.stringify({
  name: "deepseek-harness-macos-runtime",
  version: "0.0.1",
  private: true,
  dependencies: {
    "@deepseek-ai/dsh": harnessVersion,
    pnpm: pnpmVersion
  }
}, null, 2) + "\n");
NODE

printf 'Resolving Harness %s and pnpm %s\n' "$HARNESS_VERSION" "$PNPM_VERSION"
(
    cd "$HARNESS_ROOT"
    "$NODE_EXECUTABLE" "$NPM_CLI" install \
        --ignore-scripts \
        --include=optional \
        --no-audit \
        --no-fund \
        --registry "$REGISTRY"
    rm -rf node_modules
    "$NODE_EXECUTABLE" "$NPM_CLI" ci \
        --ignore-scripts \
        --include=optional \
        --no-audit \
        --no-fund \
        --registry "$REGISTRY"
)

# @deepseek-ai/dsh-session-persistence-jsonl (added in Harness 0.1.3-alpha.2)
# depends on fs-ext, a native module that ships no prebuilt binding and is
# built by its install script. Keep --ignore-scripts for the rest of the tree,
# but compile just this module here so the packaged Runtime boots on macOS.
# node-gyp's shebang runs "env node", so the downloaded Node must lead PATH;
# otherwise the hosted runner's own Node builds the binding against a
# different NODE_MODULE_VERSION and dlopen fails at boot.
FS_EXT_ROOT="$HARNESS_ROOT/node_modules/fs-ext"
if [ -d "$FS_EXT_ROOT" ]; then
    if [ ! -f "$FS_EXT_ROOT/build/Release/fs_ext.node" ]; then
        printf 'Compiling fs-ext native binding for %s\n' "$ARCHITECTURE"
        (
            cd "$HARNESS_ROOT"
            PATH="$(dirname "$NODE_EXECUTABLE"):$PATH" \
                "$NODE_EXECUTABLE" "$NPM_CLI" rebuild fs-ext
        )
    fi

    # Always load the binding, whether it was rebuilt here or came prebuilt:
    # a wrong architecture or a wrong ABI only fails at boot, when a session is
    # created, which is far too late to catch during a release.
    "$NODE_EXECUTABLE" -e 'require(process.argv[1])' "$FS_EXT_ROOT" || die \
        "fs-ext native binding failed to load with the packaged Node"

    # node-gyp leaves object files, dependency files and Makefiles carrying
    # absolute build paths inside build/. Keep only the loadable binding so the
    # immutable artifact carries no temporary build material.
    if [ -d "$FS_EXT_ROOT/build" ]; then
        find "$FS_EXT_ROOT/build" -type f ! -name '*.node' -delete
        find "$FS_EXT_ROOT/build" -mindepth 1 -type d -empty -delete
    fi

    "$NODE_EXECUTABLE" -e 'require(process.argv[1])' "$FS_EXT_ROOT" || die \
        "fs-ext native binding failed to load after removing build material"
fi

HARNESS_ENTRY="$HARNESS_ROOT/node_modules/@deepseek-ai/dsh/lib/bin.js"
PNPM_PACKAGE="$HARNESS_ROOT/node_modules/pnpm/package.json"
PNPM_EXECUTABLE="$HARNESS_ROOT/node_modules/.bin/pnpm"
[ -f "$HARNESS_ENTRY" ] || die "Harness entry point is missing"
[ -f "$PNPM_PACKAGE" ] || die "pnpm package is missing"
[ -x "$PNPM_EXECUTABLE" ] || die "pnpm shim is missing or not executable"

NATIVE_ROOT="$HARNESS_ROOT/node_modules/node-pty/prebuilds/$ARCHITECTURE"
PTY_BINARY="$NATIVE_ROOT/pty.node"
SPAWN_HELPER="$NATIVE_ROOT/spawn-helper"
[ -f "$PTY_BINARY" ] || die "node-pty native binary is missing"
[ -f "$SPAWN_HELPER" ] || die "node-pty spawn helper is missing"
chmod 755 "$SPAWN_HELPER"

# Which first-party plugin market works is decided by the Harness version this
# artifact ships, and only the publisher knows that pairing — so it is resolved
# here and written into the manifest, where DSH Studio reads it instead of
# relying on a version compiled into the app.
PLUGIN_MARKET_FILE="$WORK_DIR/plugin-market.json"
resolve_plugin_market() {
    local arguments=(--harness "$HARNESS_VERSION" --registry "$REGISTRY" --package "$PLUGIN_MARKET_PACKAGE")
    if [ -n "$PLUGIN_MARKET_VERSION" ]; then
        arguments+=(--version "$PLUGIN_MARKET_VERSION")
    fi
    "$NODE_EXECUTABLE" "$SCRIPT_DIR/resolve-plugin-market.js" "${arguments[@]}" > "$PLUGIN_MARKET_FILE"
}

printf 'Resolving the plugin market pin for Harness %s\n' "$HARNESS_VERSION"
if ! resolve_plugin_market; then
    if [ "${DSH_RUNTIME_ALLOW_MISSING_PLUGIN_MARKET:-0}" = "1" ]; then
        printf 'WARNING: publishing without a plugin market pin; DSH Studio falls back to its compiled pin.\n' >&2
        printf 'null\n' > "$PLUGIN_MARKET_FILE"
    else
        die "could not resolve a $PLUGIN_MARKET_PACKAGE version for Harness $HARNESS_VERSION: wait for a market release that covers it, pin one with PLUGIN_MARKET_VERSION=<version>, or set DSH_RUNTIME_ALLOW_MISSING_PLUGIN_MARKET=1 to publish without a pin"
    fi
fi

export DSH_RUNTIME_VERSION="$RUNTIME_VERSION"
export DSH_RUNTIME_PLATFORM="$RUNTIME_PLATFORM"
export DSH_RUNTIME_ARCHITECTURE="$ARCHITECTURE"
export DSH_RUNTIME_NODE_VERSION="$NODE_VERSION"
export DSH_RUNTIME_HARNESS_VERSION="$HARNESS_VERSION"
export DSH_RUNTIME_PNPM_VERSION="$PNPM_VERSION"
export DSH_RUNTIME_NODE_SHA256="$ACTUAL_NODE_SHA256"
export DSH_RUNTIME_REGISTRY="$REGISTRY"
export DSH_RUNTIME_LOCK_SHA256="$(shasum -a 256 "$HARNESS_ROOT/package-lock.json" | awk '{print $1}')"
export DSH_RUNTIME_PLUGIN_MARKET_FILE="$PLUGIN_MARKET_FILE"
export DSH_RUNTIME_SOURCE_COMMIT="${BUILD_SOURCE_COMMIT:-}"
export DSH_RUNTIME_SOURCE_REF="${BUILD_SOURCE_REF:-}"
export DSH_RUNTIME_RUN_ID="${BUILD_RUN_ID:-}"
export DSH_RUNTIME_DATA_FORMAT_ID="$DATA_FORMAT_ID"
export DSH_RUNTIME_DATA_FORMAT_COMPATIBLE_WITH="$DATA_FORMAT_COMPATIBLE_WITH"
export DSH_RUNTIME_DATA_FORMAT_MIGRATION="$DATA_FORMAT_MIGRATION"

"$NODE_EXECUTABLE" - "$HARNESS_ROOT/package-lock.json" "$STAGE_DIR/manifest.json" <<'NODE'
const fs = require("fs");
const [lockPath, manifestPath] = process.argv.slice(2);
const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
const packages = lock.packages || {};
const root = packages[""] || {};
const dependencies = root.dependencies || {};
const harness = packages["node_modules/@deepseek-ai/dsh"];
const pnpm = packages["node_modules/pnpm"];
const expectedHarness = process.env.DSH_RUNTIME_HARNESS_VERSION;
const expectedPnpm = process.env.DSH_RUNTIME_PNPM_VERSION;
const dataFormatID = process.env.DSH_RUNTIME_DATA_FORMAT_ID;
const compatibleWith = (process.env.DSH_RUNTIME_DATA_FORMAT_COMPATIBLE_WITH || "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const pluginMarket = JSON.parse(fs.readFileSync(process.env.DSH_RUNTIME_PLUGIN_MARKET_FILE, "utf8"));
if (pluginMarket !== null &&
    (!pluginMarket.package || !pluginMarket.version || !pluginMarket.integrity ||
     (pluginMarket.harnessRange != null && !pluginMarket.harnessRange))) {
  throw new Error("the resolved plugin market pin is incomplete");
}
if (lock.lockfileVersion !== 3 ||
    dependencies["@deepseek-ai/dsh"] !== expectedHarness ||
    dependencies.pnpm !== expectedPnpm ||
    !harness || harness.version !== expectedHarness || !harness.integrity ||
    !pnpm || pnpm.version !== expectedPnpm || !pnpm.integrity) {
  throw new Error("generated package-lock.json does not match the resolved Runtime");
}
const manifest = {
  schemaVersion: 3,
  runtimeVersion: process.env.DSH_RUNTIME_VERSION,
  platform: process.env.DSH_RUNTIME_PLATFORM,
  architecture: process.env.DSH_RUNTIME_ARCHITECTURE,
  nodeVersion: process.env.DSH_RUNTIME_NODE_VERSION,
  harnessVersion: expectedHarness,
  pnpmVersion: expectedPnpm,
  nodeSHA256: process.env.DSH_RUNTIME_NODE_SHA256,
  harnessPackageIntegrity: harness.integrity,
  pnpmPackageIntegrity: pnpm.integrity,
  registry: process.env.DSH_RUNTIME_REGISTRY,
  dependencyLockSHA256: process.env.DSH_RUNTIME_LOCK_SHA256,
  pluginMarket: pluginMarket === null ? null : {
    package: pluginMarket.package,
    version: pluginMarket.version,
    integrity: pluginMarket.integrity,
    harnessRange: pluginMarket.harnessRange || null
  },
  dataFormat: dataFormatID ? {
    id: dataFormatID,
    compatibleWith,
    migration: process.env.DSH_RUNTIME_DATA_FORMAT_MIGRATION || null
  } : null
};
// Provenance is recorded when the release pipeline builds the Runtime and left
// out of local builds, so a published artifact can always be traced back to the
// commit and run that produced it.
const provenance = {
  commit: process.env.DSH_RUNTIME_SOURCE_COMMIT,
  ref: process.env.DSH_RUNTIME_SOURCE_REF,
  runId: process.env.DSH_RUNTIME_RUN_ID
};
if (provenance.commit || provenance.ref || provenance.runId) {
  manifest.provenance = provenance;
}
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
NODE

mkdir -p "$OUTPUT_DIR"
ARTIFACT_NAME="dsh-runtime-$RUNTIME_VERSION-$ARCHITECTURE.tar.gz"
ARTIFACT_PATH="$OUTPUT_DIR/$ARTIFACT_NAME"

# DSH Studio accepts exactly manifest.json plus the node/ and harness/ trees, so
# macOS metadata must never reach the archive: a stray ._manifest.json or
# .DS_Store at the archive root makes the app reject the whole artifact.
# Members are written in sorted order with a fixed owner, and gzip runs with -n
# so the header carries neither a build timestamp nor a local file name.
(
    cd "$STAGE_DIR"
    find manifest.json node harness -print | LC_ALL=C sort
) | COPYFILE_DISABLE=1 tar -cf - \
        --no-recursion \
        --no-mac-metadata \
        --uid 0 --gid 0 --uname root --gname root \
        --exclude '.DS_Store' \
        --exclude '._*' \
        --exclude '*/._*' \
        -C "$STAGE_DIR" \
        -T - | gzip -n -9 > "$ARTIFACT_PATH"

ARTIFACT_SHA256="$(shasum -a 256 "$ARTIFACT_PATH" | awk '{print $1}')"
ARTIFACT_SIZE="$(wc -c < "$ARTIFACT_PATH" | tr -d '[:space:]')"
export DSH_RUNTIME_ARTIFACT_SHA256="$ARTIFACT_SHA256"
export DSH_RUNTIME_ARTIFACT_SIZE="$ARTIFACT_SIZE"

# The smoke test runs against the published bytes, not against the staging tree:
# a lost permission bit, a missing member or an unreadable archive only shows up
# after packing.
VERIFY_ROOT="$WORK_DIR/verify"
mkdir -p "$VERIFY_ROOT"
tar -xzf "$ARTIFACT_PATH" -C "$VERIFY_ROOT"
"$SCRIPT_DIR/runtime-smoke.sh" "$VERIFY_ROOT"

cp "$STAGE_DIR/manifest.json" "$OUTPUT_DIR/manifest-$RUNTIME_VERSION-$ARCHITECTURE.json"

"$NODE_EXECUTABLE" - \
    "$STAGE_DIR/manifest.json" \
    "$OUTPUT_DIR/artifact-$RUNTIME_VERSION-$ARCHITECTURE.json" \
    "$ARTIFACT_BASE_URL" \
    "$ARTIFACT_NAME" <<'NODE'
const fs = require("fs");
const [manifestPath, outputPath, artifactBaseURL, artifactName] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const metadata = {
  runtimeVersion: manifest.runtimeVersion,
  platform: manifest.platform,
  architecture: manifest.architecture,
  nodeVersion: manifest.nodeVersion,
  harnessVersion: manifest.harnessVersion,
  pnpmVersion: manifest.pnpmVersion,
  nodeArchiveSHA256: manifest.nodeSHA256,
  harnessPackageIntegrity: manifest.harnessPackageIntegrity,
  pnpmPackageIntegrity: manifest.pnpmPackageIntegrity,
  dependencyLockSHA256: manifest.dependencyLockSHA256,
  provenance: manifest.provenance || null,
  pluginMarket: manifest.pluginMarket,
  dataFormat: manifest.dataFormat,
  artifact: artifactName,
  sha256: process.env.DSH_RUNTIME_ARTIFACT_SHA256,
  size: Number(process.env.DSH_RUNTIME_ARTIFACT_SIZE),
  url: `${artifactBaseURL}/${artifactName}`,
  manifest: `manifest-${manifest.runtimeVersion}-${manifest.architecture}.json`
};
fs.writeFileSync(outputPath, JSON.stringify(metadata, null, 2) + "\n");
NODE

printf 'Runtime artifact ready: %s\n' "$ARTIFACT_PATH"
printf 'Runtime artifact SHA-256: %s\n' "$ARTIFACT_SHA256"
printf 'Runtime artifact size: %s bytes\n' "$ARTIFACT_SIZE"
printf 'Harness version (Runtime version): %s\n' "$HARNESS_VERSION"
printf 'pnpm version: %s\n' "$PNPM_VERSION"
