#!/usr/bin/env bash
set -euo pipefail

# Offline test suite for the Runtime distribution tooling.
#
# It needs no network, no secret and no macOS: everything runs against fixtures
# in a temporary directory, so pull requests (including forks) can run it
# without ever touching the signing key. The positive end-to-end path is the
# build job in runtime-builder.yml.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-runtime-tests.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

PASSED=0
FAILED=0

pass() {
    PASSED=$((PASSED + 1))
    printf '  ok    %s\n' "$1"
}

fail_test() {
    FAILED=$((FAILED + 1))
    printf '  FAIL  %s\n' "$1"
    sed -n '1,20p' "$WORK_DIR/output.log" 2>/dev/null | sed 's/^/        /' || true
}

expect_success() {
    local name="$1"
    shift
    if "$@" >"$WORK_DIR/output.log" 2>&1; then
        pass "$name"
    else
        fail_test "$name"
    fi
}

expect_failure() {
    local name="$1"
    shift
    if "$@" >"$WORK_DIR/output.log" 2>&1; then
        fail_test "$name (expected a non-zero exit)"
    else
        pass "$name"
    fi
}

expect_failure_matching() {
    local name="$1" pattern="$2"
    shift 2
    if "$@" >"$WORK_DIR/output.log" 2>&1; then
        fail_test "$name (expected a non-zero exit)"
    elif grep -q "$pattern" "$WORK_DIR/output.log"; then
        pass "$name"
    else
        fail_test "$name (expected output matching: $pattern)"
    fi
}

expect_success_matching() {
    local name="$1" pattern="$2"
    shift 2
    if "$@" >"$WORK_DIR/output.log" 2>&1 && grep -q "$pattern" "$WORK_DIR/output.log"; then
        pass "$name"
    else
        fail_test "$name (expected success with output matching: $pattern)"
    fi
}

edit_json() {
    # edit_json FILE 'javascript statements mutating the parsed "value"'
    local file="$1" statements="$2"
    node -e '
const fs = require("fs");
const file = process.argv[1];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
eval(process.argv[2]);
fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
' "$file" "$statements"
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

# A pair of metadata files plus the artifacts they describe, all small enough to
# keep the suite fast. The version is the Harness version; the optional salt
# changes the artifact bytes, which is how the suite builds two different
# artifacts for the same Runtime version.
make_fixture() {
    local directory="$1" version="$2" salt="${3:-}"
    mkdir -p "$directory"
    local architecture artifact
    for architecture in darwin-arm64 darwin-x64; do
        artifact="dsh-runtime-$version-$architecture.tar.gz"
        printf 'fixture artifact %s %s\n' "$artifact" "$salt" > "$directory/$artifact"
        cat > "$directory/artifact-$version-$architecture.json" <<JSON
{
  "runtimeVersion": "$version",
  "platform": "macos",
  "architecture": "$architecture",
  "nodeVersion": "24.19.0",
  "harnessVersion": "$version",
  "pnpmVersion": "11.22.0",
  "nodeArchiveSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "harnessPackageIntegrity": "sha512-fixture-harness",
  "pnpmPackageIntegrity": "sha512-fixture-pnpm",
  "dependencyLockSHA256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "pluginMarket": {
    "package": "dshmarket",
    "version": "1.66.5",
    "integrity": "sha512-fixture-market",
    "harnessRange": "^0.1.0 || ^0.2.0"
  },
  "dataFormat": { "id": "sqlite-v2", "compatibleWith": [], "migration": null },
  "artifact": "$artifact",
  "sha256": "$(sha256_of "$directory/$artifact")",
  "size": $(wc -c < "$directory/$artifact" | tr -d '[:space:]'),
  "url": "https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-$version/$artifact",
  "manifest": "manifest-$version-$architecture.json"
}
JSON
    done
}

make_catalog() {
    # make_catalog DIRECTORY VERSION [SALT] -> DIRECTORY/catalog.json
    local directory="$1" version="$2" salt="${3:-}"
    make_fixture "$directory" "$version" "$salt"
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
        "$version" "$directory/catalog.json" \
        "$directory"/artifact-*.json >/dev/null
}

# A tree shaped like an extracted artifact, used to prove the smoke test fails
# closed. The Node binary is the host's, so manifest parsing behaves normally.
make_fake_runtime() {
    local root="$1"
    local harness_root="$root/harness/darwin-arm64/0.1.1-rc.2"
    rm -rf "$root"
    mkdir -p "$root/node/darwin-arm64/bin" \
        "$harness_root/node_modules/@deepseek-ai/dsh/lib" \
        "$harness_root/node_modules/.bin" \
        "$harness_root/node_modules/node-pty/prebuilds/darwin-arm64"
    ln -sf "$(command -v node)" "$root/node/darwin-arm64/bin/node"
    printf 'module.exports = {};\n' > "$harness_root/node_modules/@deepseek-ai/dsh/lib/bin.js"
    printf '#!/bin/sh\n' > "$harness_root/node_modules/.bin/pnpm"
    chmod +x "$harness_root/node_modules/.bin/pnpm"
    : > "$harness_root/node_modules/node-pty/prebuilds/darwin-arm64/pty.node"
    : > "$harness_root/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper"
    chmod +x "$harness_root/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper"
    # The confinement seam and the credential provider are loaded by the smoke
    # test, so the fixture carries stubs with the shape the published packages
    # have (ESM entry point, provider class, mode list).
    for stub in dsh-sandbox-local dsh-credentials-local; do
        mkdir -p "$harness_root/node_modules/@deepseek-ai/$stub/lib"
        printf '{"name":"@deepseek-ai/%s","type":"module","main":"lib/index.js"}\n' "$stub" \
            > "$harness_root/node_modules/@deepseek-ai/$stub/package.json"
        printf 'export default class Provider {}\n' \
            > "$harness_root/node_modules/@deepseek-ai/$stub/lib/index.js"
    done
    mkdir -p "$harness_root/node_modules/@deepseek-ai/dsh-sandbox-policy/lib"
    printf '{"name":"@deepseek-ai/dsh-sandbox-policy","type":"module","main":"lib/index.js"}\n' \
        > "$harness_root/node_modules/@deepseek-ai/dsh-sandbox-policy/package.json"
    printf 'export const SANDBOX_MODES = ["read-only", "workspace-write", "danger-full-access"];\n' \
        > "$harness_root/node_modules/@deepseek-ai/dsh-sandbox-policy/lib/index.js"
    cat > "$root/manifest.json" <<'JSON'
{
  "schemaVersion": 3,
  "runtimeVersion": "0.1.1-rc.2",
  "platform": "macos",
  "architecture": "darwin-arm64",
  "nodeVersion": "24.19.0",
  "harnessVersion": "0.1.1-rc.2",
  "pnpmVersion": "11.22.0",
  "nodeSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "harnessPackageIntegrity": "sha512-fixture-harness",
  "pnpmPackageIntegrity": "sha512-fixture-pnpm",
  "dataFormat": { "id": "sqlite-v2", "compatibleWith": [], "migration": null }
}
JSON
}

echo "build-runtime.sh input validation"
expect_failure "rejects a version that is not a Harness version" \
    env RUNTIME_VERSION=not-a-version "$SCRIPT_DIR/build-runtime.sh"
expect_failure "rejects the retired -verN build counter" \
    env RUNTIME_VERSION=0.2.0-rc.1-ver2 "$SCRIPT_DIR/build-runtime.sh"
expect_failure "rejects an -r2 build counter" \
    env RUNTIME_VERSION=0.2.0-rc.1-r2 "$SCRIPT_DIR/build-runtime.sh"
expect_failure "rejects a -rebuild-2 build counter" \
    env RUNTIME_VERSION=0.2.0-rc.1-rebuild-2 "$SCRIPT_DIR/build-runtime.sh"
expect_failure "rejects a -revision-2 build counter" \
    env RUNTIME_VERSION=0.2.0-rc.1-revision-2 "$SCRIPT_DIR/build-runtime.sh"
expect_failure "rejects a path-like version" \
    env RUNTIME_VERSION=..-ver1 "$SCRIPT_DIR/build-runtime.sh"
expect_failure "rejects a Harness version that contradicts the Runtime version" \
    env RUNTIME_VERSION=0.2.0-rc.1 HARNESS_VERSION=0.2.0-rc.2 PNPM_VERSION=11.22.0 \
    "$SCRIPT_DIR/build-runtime.sh"
# The closest an offline test gets to the accepted path: a bare Harness version
# has to clear validation and stop at the next missing pin instead.
expect_failure_matching "accepts a bare Harness version and stops at the missing pin" \
    "PNPM_VERSION is required" \
    env RUNTIME_VERSION=0.2.0-rc.1 "$SCRIPT_DIR/build-runtime.sh"
expect_failure_matching "accepts a plain release version" \
    "PNPM_VERSION is required" \
    env RUNTIME_VERSION=1.0.0 "$SCRIPT_DIR/build-runtime.sh"

echo "generate-runtime-catalog.sh"
make_fixture "$WORK_DIR/ok" "0.1.1-rc.2"
expect_success "merges both architectures into one catalog" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/ok/catalog.json" "$WORK_DIR"/ok/artifact-*.json
expect_success "catalog carries the Harness version, platform, size and data format" \
    node -e '
const fs = require("fs");
const assert = require("assert");
const catalog = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
assert.strictEqual(catalog.schemaVersion, 1);
assert.strictEqual(catalog.runtimeVersion, "0.1.1-rc.2");
assert.strictEqual(catalog.releases.length, 2);
for (const release of catalog.releases) {
  // One Harness version is one current Runtime: the release names the upstream
  // version, and nothing carries a build counter any more.
  assert.strictEqual(release.runtimeVersion, "0.1.1-rc.2");
  assert.strictEqual(release.harnessVersion, "0.1.1-rc.2");
  assert.strictEqual(release.platform, "macos");
  assert.strictEqual(release.runtimeRevision, undefined);
  assert.strictEqual(release.dataFormat.id, "sqlite-v2");
  assert.ok(release.artifact.size > 0);
  assert.match(release.artifact.sha256, /^[0-9a-f]{64}$/);
  assert.strictEqual(release.pluginMarket.package, "dshmarket");
  assert.strictEqual(release.pluginMarket.version, "1.66.5");
  assert.strictEqual(release.pluginMarket.integrity, "sha512-fixture-market");
  assert.strictEqual(release.pluginMarket.harnessRange, "^0.1.0 || ^0.2.0");
  // The artifact name is the version and the architecture, with no suffix.
  assert.strictEqual(release.artifact.url.endsWith(`/runtime-0.1.1-rc.2/dsh-runtime-0.1.1-rc.2-${release.architecture}.tar.gz`), true);
  assert.doesNotMatch(release.artifact.url, /-ver[0-9]|-r[0-9]|-rebuild-|-revision-/);
}
assert.ok(catalog.releases.find((release) => release.architecture === "darwin-arm64"));
assert.ok(catalog.releases.find((release) => release.architecture === "darwin-x64"));
' "$WORK_DIR/ok/catalog.json"

expect_failure "refuses a version that is not a Harness version" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "not-a-version" "$WORK_DIR/ok/bad-version.json" "$WORK_DIR"/ok/artifact-*.json
expect_failure "refuses the retired -verN build counter" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2-ver1" "$WORK_DIR/ok/legacy-version.json" "$WORK_DIR"/ok/artifact-*.json
expect_failure "refuses metadata from a different Runtime version" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.3" "$WORK_DIR/ok/mismatch.json" "$WORK_DIR"/ok/artifact-*.json
expect_failure "refuses a single architecture" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/ok/single.json" "$WORK_DIR/ok/artifact-0.1.1-rc.2-darwin-arm64.json"

cp -R "$WORK_DIR/ok" "$WORK_DIR/no-data-format"
node -e '
const fs = require("fs");
for (const file of process.argv.slice(1)) {
  const metadata = JSON.parse(fs.readFileSync(file, "utf8"));
  delete metadata.dataFormat;
  fs.writeFileSync(file, JSON.stringify(metadata, null, 2));
}
' "$WORK_DIR"/no-data-format/artifact-*.json
expect_failure "refuses metadata without a data format" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/no-data-format/catalog.json" "$WORK_DIR"/no-data-format/artifact-*.json

cp -R "$WORK_DIR/ok" "$WORK_DIR/missing-artifact"
rm "$WORK_DIR/missing-artifact/dsh-runtime-0.1.1-rc.2-darwin-x64.tar.gz"
expect_failure "refuses metadata whose artifact is missing" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/missing-artifact/catalog.json" "$WORK_DIR"/missing-artifact/artifact-*.json
expect_success "allows a missing artifact only when explicitly asked" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/missing-artifact/catalog.json" "$WORK_DIR"/missing-artifact/artifact-*.json \
    --allow-missing-artifacts

cp -R "$WORK_DIR/ok" "$WORK_DIR/tampered-artifact"
printf 'tampered\n' >> "$WORK_DIR/tampered-artifact/dsh-runtime-0.1.1-rc.2-darwin-arm64.tar.gz"
expect_failure "refuses an artifact that does not match its checksum" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/tampered-artifact/catalog.json" "$WORK_DIR"/tampered-artifact/artifact-*.json

cp -R "$WORK_DIR/ok" "$WORK_DIR/bad-size"
edit_json "$WORK_DIR/bad-size/artifact-0.1.1-rc.2-darwin-arm64.json" 'value.size = value.size + 1'
expect_failure "refuses an artifact that does not match its recorded size" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/bad-size/catalog.json" "$WORK_DIR"/bad-size/artifact-*.json

cp -R "$WORK_DIR/ok" "$WORK_DIR/bad-name"
edit_json "$WORK_DIR/bad-name/artifact-0.1.1-rc.2-darwin-arm64.json" 'value.artifact = "dsh-runtime-other.tar.gz"'
expect_failure "refuses metadata whose artifact name does not follow the version" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/bad-name/catalog.json" "$WORK_DIR"/bad-name/artifact-*.json

cp -R "$WORK_DIR/ok" "$WORK_DIR/bad-contract"
edit_json "$WORK_DIR/bad-contract/artifact-0.1.1-rc.2-darwin-x64.json" 'value.nodeVersion = "24.20.0"'
expect_failure "refuses architectures that disagree about the Runtime contract" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/bad-contract/catalog.json" "$WORK_DIR"/bad-contract/artifact-*.json

cp -R "$WORK_DIR/ok" "$WORK_DIR/bad-harness"
edit_json "$WORK_DIR/bad-harness/artifact-0.1.1-rc.2-darwin-x64.json" 'value.harnessVersion = "0.1.1-rc.3"'
expect_failure "refuses metadata whose Harness version disagrees with the version" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/bad-harness/catalog.json" "$WORK_DIR"/bad-harness/artifact-*.json

cp -R "$WORK_DIR/ok" "$WORK_DIR/no-pin"
node -e '
const fs = require("fs");
for (const file of process.argv.slice(1)) {
  const metadata = JSON.parse(fs.readFileSync(file, "utf8"));
  delete metadata.pluginMarket;
  fs.writeFileSync(file, JSON.stringify(metadata, null, 2));
}
' "$WORK_DIR"/no-pin/artifact-*.json
expect_failure "refuses metadata that never decided on a plugin market pin" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/no-pin/catalog.json" "$WORK_DIR"/no-pin/artifact-*.json

cp -R "$WORK_DIR/ok" "$WORK_DIR/bad-pin"
edit_json "$WORK_DIR/bad-pin/artifact-0.1.1-rc.2-darwin-x64.json" 'value.pluginMarket.integrity = ""'
expect_failure "refuses a plugin market pin without an integrity" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/bad-pin/catalog.json" "$WORK_DIR"/bad-pin/artifact-*.json

cp -R "$WORK_DIR/ok" "$WORK_DIR/pin-contract"
edit_json "$WORK_DIR/pin-contract/artifact-0.1.1-rc.2-darwin-x64.json" 'value.pluginMarket.version = "1.70.0"'
expect_failure "refuses architectures that disagree about the plugin market pin" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/pin-contract/catalog.json" "$WORK_DIR"/pin-contract/artifact-*.json

cp -R "$WORK_DIR/ok" "$WORK_DIR/null-pin"
node -e '
const fs = require("fs");
for (const file of process.argv.slice(1)) {
  const metadata = JSON.parse(fs.readFileSync(file, "utf8"));
  metadata.pluginMarket = null;
  fs.writeFileSync(file, JSON.stringify(metadata, null, 2));
}
' "$WORK_DIR"/null-pin/artifact-*.json
expect_success "publishes no plugin market pin when that decision is explicit" \
    "$SCRIPT_DIR/generate-runtime-catalog.sh" \
    "0.1.1-rc.2" "$WORK_DIR/null-pin/catalog.json" "$WORK_DIR"/null-pin/artifact-*.json

echo "signing and signature verification"
node -e '
const crypto = require("crypto");
const { privateKey } = crypto.generateKeyPairSync("ed25519");
const publicKey = crypto.createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32);
process.stdout.write(privateKey.export({ format: "der", type: "pkcs8" }).toString("base64") + "\n");
process.stdout.write(publicKey.toString("base64") + "\n");
' > "$WORK_DIR/keypair.txt"
PRIVATE_KEY="$(sed -n 1p "$WORK_DIR/keypair.txt")"
PUBLIC_KEY="$(sed -n 2p "$WORK_DIR/keypair.txt")"
node -e '
const crypto = require("crypto");
const { privateKey } = crypto.generateKeyPairSync("ed25519");
process.stdout.write(crypto.createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32).toString("base64") + "\n");
' > "$WORK_DIR/other-public-key.txt"

expect_success "signs a catalog with a matching trust anchor" \
    env RUNTIME_CATALOG_PRIVATE_KEY_BASE64="$PRIVATE_KEY" RUNTIME_CATALOG_PUBLIC_KEY="$PUBLIC_KEY" \
    "$SCRIPT_DIR/sign-runtime-catalog.sh" "$WORK_DIR/ok/catalog.json" "$WORK_DIR/ok/catalog.signed.json"
expect_success "the signed catalog verifies with the trust anchor" \
    "$SCRIPT_DIR/verify-runtime-catalog.sh" \
    "$WORK_DIR/ok/catalog.signed.json" "$PUBLIC_KEY" "$WORK_DIR/ok/payload.json"
expect_failure "refuses to sign with a different key than the trust anchor" \
    env RUNTIME_CATALOG_PRIVATE_KEY_BASE64="$PRIVATE_KEY" \
    RUNTIME_CATALOG_PUBLIC_KEY="$(cat "$WORK_DIR/other-public-key.txt")" \
    "$SCRIPT_DIR/sign-runtime-catalog.sh" "$WORK_DIR/ok/catalog.json" "$WORK_DIR/ok/wrong-anchor.signed.json"
expect_failure "refuses to sign without the trust anchor" \
    env RUNTIME_CATALOG_PRIVATE_KEY_BASE64="$PRIVATE_KEY" \
    "$SCRIPT_DIR/sign-runtime-catalog.sh" "$WORK_DIR/ok/catalog.json" "$WORK_DIR/ok/no-anchor.signed.json"
expect_failure "refuses to sign without a key" \
    env RUNTIME_CATALOG_PUBLIC_KEY="$PUBLIC_KEY" \
    "$SCRIPT_DIR/sign-runtime-catalog.sh" "$WORK_DIR/ok/catalog.json" "$WORK_DIR/ok/no-key.signed.json"
expect_failure "refuses two private key sources at once" \
    env RUNTIME_CATALOG_PRIVATE_KEY_BASE64="$PRIVATE_KEY" RUNTIME_CATALOG_PRIVATE_KEY_PATH="$WORK_DIR/keypair.txt" \
    RUNTIME_CATALOG_PUBLIC_KEY="$PUBLIC_KEY" \
    "$SCRIPT_DIR/sign-runtime-catalog.sh" "$WORK_DIR/ok/catalog.json" "$WORK_DIR/ok/two-keys.signed.json"

# The key can also be read from a file, which is the shape an operator restoring
# it from a backup may hold: PEM is self-describing, a PKCS#8 DER file is not.
node -e '
const crypto = require("crypto");
const fs = require("fs");
const der = Buffer.from(process.argv[1], "base64");
const dir = process.argv[2];
const key = crypto.createPrivateKey({ key: der, format: "der", type: "pkcs8" });
fs.writeFileSync(dir + "/key.der", der, { mode: 0o600 });
fs.writeFileSync(dir + "/key.pem", key.export({ format: "pem", type: "pkcs8" }), { mode: 0o600 });
const corrupted = Buffer.from(der);
corrupted[corrupted.length - 1] ^= 0x01;
fs.writeFileSync(dir + "/key-corrupted.der", corrupted, { mode: 0o600 });
fs.writeFileSync(dir + "/key-not-a-key.txt", "not a private key\n", { mode: 0o600 });
' "$PRIVATE_KEY" "$WORK_DIR"
expect_success "signs with a PKCS#8 DER key file" \
    env RUNTIME_CATALOG_PRIVATE_KEY_PATH="$WORK_DIR/key.der" RUNTIME_CATALOG_PUBLIC_KEY="$PUBLIC_KEY" \
    "$SCRIPT_DIR/sign-runtime-catalog.sh" "$WORK_DIR/ok/catalog.json" "$WORK_DIR/ok/der.signed.json"
expect_success "signs with a PEM key file" \
    env RUNTIME_CATALOG_PRIVATE_KEY_PATH="$WORK_DIR/key.pem" RUNTIME_CATALOG_PUBLIC_KEY="$PUBLIC_KEY" \
    "$SCRIPT_DIR/sign-runtime-catalog.sh" "$WORK_DIR/ok/catalog.json" "$WORK_DIR/ok/pem.signed.json"
expect_success "produces the same signature from base64 DER, a DER file and a PEM file" \
    node -e '
const assert = require("assert");
const fs = require("fs");
const dir = process.argv[1];
const signatureOf = (name) => JSON.parse(fs.readFileSync(`${dir}/${name}`, "utf8")).signature;
const fromBase64 = signatureOf("catalog.signed.json");
assert.strictEqual(signatureOf("der.signed.json"), fromBase64, "the DER key file signed differently");
assert.strictEqual(signatureOf("pem.signed.json"), fromBase64, "the PEM key file signed differently");
' "$WORK_DIR/ok"
expect_failure "refuses to sign with a corrupted key file" \
    env RUNTIME_CATALOG_PRIVATE_KEY_PATH="$WORK_DIR/key-corrupted.der" RUNTIME_CATALOG_PUBLIC_KEY="$PUBLIC_KEY" \
    "$SCRIPT_DIR/sign-runtime-catalog.sh" "$WORK_DIR/ok/catalog.json" "$WORK_DIR/ok/corrupted-key.signed.json"
expect_failure_matching "refuses a key file that is neither PEM nor PKCS#8 DER" \
    "neither PEM nor PKCS#8 DER" \
    env RUNTIME_CATALOG_PRIVATE_KEY_PATH="$WORK_DIR/key-not-a-key.txt" RUNTIME_CATALOG_PUBLIC_KEY="$PUBLIC_KEY" \
    "$SCRIPT_DIR/sign-runtime-catalog.sh" "$WORK_DIR/ok/catalog.json" "$WORK_DIR/ok/not-a-key.signed.json"
expect_failure "rejects a catalog whose signature does not match" \
    "$SCRIPT_DIR/verify-runtime-catalog.sh" \
    "$WORK_DIR/ok/catalog.signed.json" "$(cat "$WORK_DIR/other-public-key.txt")"
expect_failure "rejects a catalog with an unexpected key ID" \
    env RUNTIME_CATALOG_KEY_ID=runtime-catalog-v2 \
    "$SCRIPT_DIR/verify-runtime-catalog.sh" "$WORK_DIR/ok/catalog.signed.json" "$PUBLIC_KEY"

cp "$WORK_DIR/ok/catalog.signed.json" "$WORK_DIR/ok/tampered.signed.json"
node -e '
const fs = require("fs");
const file = process.argv[1];
const envelope = JSON.parse(fs.readFileSync(file, "utf8"));
const payload = Buffer.from(envelope.payload, "base64");
payload[payload.length - 2] = payload[payload.length - 2] ^ 0x01;
envelope.payload = payload.toString("base64");
fs.writeFileSync(file, JSON.stringify(envelope, null, 2));
' "$WORK_DIR/ok/tampered.signed.json"
expect_failure "rejects a tampered payload" \
    "$SCRIPT_DIR/verify-runtime-catalog.sh" "$WORK_DIR/ok/tampered.signed.json" "$PUBLIC_KEY"

cp "$WORK_DIR/ok/catalog.signed.json" "$WORK_DIR/ok/url-tampered.signed.json"
node -e '
const fs = require("fs");
const file = process.argv[1];
const envelope = JSON.parse(fs.readFileSync(file, "utf8"));
const catalog = JSON.parse(Buffer.from(envelope.payload, "base64").toString("utf8"));
// Repointing an artifact at another URL is what a mutable release would look
// like; it must not survive signature verification.
catalog.releases[0].artifact.url =
  "https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-0.1.1-rc.2-ver9/dsh-runtime-0.1.1-rc.2-ver9-darwin-arm64.tar.gz";
envelope.payload = Buffer.from(JSON.stringify(catalog, null, 2), "utf8").toString("base64");
fs.writeFileSync(file, JSON.stringify(envelope, null, 2));
' "$WORK_DIR/ok/url-tampered.signed.json"
expect_failure "rejects a catalog whose artifact URL was rewritten" \
    "$SCRIPT_DIR/verify-runtime-catalog.sh" "$WORK_DIR/ok/url-tampered.signed.json" "$PUBLIC_KEY"

echo "catalog precedent"
make_catalog "$WORK_DIR/v1" "0.1.1-rc.2"
# The same Runtime version packed again: same name, different bytes.
make_catalog "$WORK_DIR/repack" "0.1.1-rc.2" "repacked"
make_catalog "$WORK_DIR/rc1" "0.1.1-rc.1"
make_catalog "$WORK_DIR/rc9" "0.1.1-rc.9"
make_catalog "$WORK_DIR/rc10" "0.1.1-rc.10"
make_catalog "$WORK_DIR/release" "0.1.1"
make_catalog "$WORK_DIR/older-harness" "1.2.3"
make_catalog "$WORK_DIR/newer-harness" "1.2.4"

expect_success "the catalog names the Harness version" \
    node -e '
const assert = require("assert");
const catalog = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
assert.strictEqual(catalog.runtimeVersion, "0.1.1-rc.2");
for (const release of catalog.releases) {
  assert.strictEqual(release.runtimeVersion, catalog.runtimeVersion);
  assert.strictEqual(release.harnessVersion, catalog.runtimeVersion);
  assert.strictEqual(release.runtimeRevision, undefined);
  assert.doesNotMatch(release.artifact.url, /-ver[0-9]|-r[0-9]|-rebuild-|-revision-/);
}
' "$WORK_DIR/v1/catalog.json"

expect_success "accepts the first published catalog" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "" "$WORK_DIR/v1/catalog.json"
expect_success "accepts a newer Harness version" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/rc1/catalog.json" "$WORK_DIR/v1/catalog.json"
expect_success "accepts a repack of the same Runtime version" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/v1/catalog.json" "$WORK_DIR/repack/catalog.json"
expect_success "accepts a republication of byte-identical assets" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/v1/catalog.json" "$WORK_DIR/v1/catalog.json"
expect_success "accepts a repack of the same Harness version across minor lines" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/older-harness/catalog.json" "$WORK_DIR/newer-harness/catalog.json"
expect_success "orders rc.10 above rc.9" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/rc9/catalog.json" "$WORK_DIR/rc10/catalog.json"
expect_success "orders a release above its prereleases" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/rc10/catalog.json" "$WORK_DIR/release/catalog.json"
expect_failure "refuses an older Harness version" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/v1/catalog.json" "$WORK_DIR/rc1/catalog.json"
expect_failure "refuses a new Harness version after a newer one" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/newer-harness/catalog.json" "$WORK_DIR/older-harness/catalog.json"
expect_failure "refuses rc.9 after rc.10" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/rc10/catalog.json" "$WORK_DIR/rc9/catalog.json"
expect_failure "refuses a prerelease after the release of the same version" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/release/catalog.json" "$WORK_DIR/rc10/catalog.json"
expect_success "allows a downgrade only when explicitly requested" \
    env ALLOW_CATALOG_DOWNGRADE=1 \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/v1/catalog.json" "$WORK_DIR/rc1/catalog.json"

expect_success_matching "a repack reports the replacement instead of failing" \
    "replacing the published darwin-arm64 artifact" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/v1/catalog.json" "$WORK_DIR/repack/catalog.json"
expect_success "a repack keeps the artifact URL and changes only the SHA-256" \
    node -e '
const assert = require("assert");
const fs = require("fs");
const first = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const second = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
// Same Runtime identity, same artifact URL, different content: SHA-256 is what
// distinguishes the builds.
assert.strictEqual(first.runtimeVersion, second.runtimeVersion);
for (const index of [0, 1]) {
  assert.strictEqual(first.releases[index].artifact.url, second.releases[index].artifact.url);
  assert.notStrictEqual(first.releases[index].artifact.sha256, second.releases[index].artifact.sha256);
}
' "$WORK_DIR/v1/catalog.json" "$WORK_DIR/repack/catalog.json"

echo "cron version selection"
# Fixed inputs only: the selector never touches the network, so these tests do
# not depend on the live npm registry or on GitHub state.
SELECT="$SCRIPT_DIR/select-next-runtime-version.sh"
SEL="$WORK_DIR/selection"
mkdir -p "$SEL"
# Upstream releases in the order the workflow emits them (ascending by
# published_at), including prereleases, plus a version below the floor.
cat > "$SEL/releases.tsv" <<'TSV'
dsh-v0.1.7-rc.1	2026-09-23T13:30:24Z
dsh-v0.1.7-rc.2	2026-09-24T14:10:21Z
dsh-v0.2.0-rc.1	2026-09-28T12:36:21Z
dsh-v0.2.0-rc.2	2026-09-29T09:42:36Z
dsh-v0.2.1-alpha.1	2026-10-03T06:42:19Z
dsh-v0.2.1-alpha.2	2026-10-09T16:18:02Z
TSV
printf 'runtime-0.1.7-rc.2\nruntime-0.2.0-rc.1\n' > "$SEL/published.txt"
: > "$SEL/skips-empty.txt"
cat > "$SEL/skips-one.txt" <<'SKIPS'
# version | until | reason
0.2.0-rc.2 | 2027-01-31 | upstream dependency graph cannot boot (fixture)
SKIPS
cat > "$SEL/skips-consecutive.txt" <<'SKIPS'
0.2.0-rc.2 | 2027-01-31 | cannot boot (fixture)
0.2.1-alpha.1 | 2027-03-31 | npm package is broken (fixture)
SKIPS
cat > "$SEL/skips-expired.txt" <<'SKIPS'
0.2.0-rc.2 | 2026-01-01 | expired window (fixture)
SKIPS
cat > "$SEL/skips-all.txt" <<'SKIPS'
0.2.0-rc.2 | 2027-01-31 | cannot boot (fixture)
0.2.1-alpha.1 | 2027-03-31 | broken (fixture)
0.2.1-alpha.2 | 2027-06-30 | broken (fixture)
SKIPS
printf '0.2.0-rc.2 |  | missing the until date\n' > "$SEL/skips-no-date.txt"
printf '0.2.0-rc.2 | 2027-13-45 | impossible date\n' > "$SEL/skips-bad-date.txt"
printf '0.2.0-rc.2 | 2027-01-31 |\n' > "$SEL/skips-no-reason.txt"
printf 'not-a-version | 2027-01-31 | bad version\n' > "$SEL/skips-bad-version.txt"

# Runs the selector and compares stdout verbatim with the expected lines.
expect_selection() {
    local name="$1" expected="$2"
    shift 2
    if "$SELECT" "$@" >"$SEL/stdout.txt" 2>"$SEL/stderr.txt"; then
        if [ "$(cat "$SEL/stdout.txt")" = "$expected" ]; then
            pass "$name"
        else
            printf '  FAIL  %s (selected: %s)\n' "$name" "$(tr '\n' ' ' < "$SEL/stdout.txt")" >&2
            fail_test "$name (unexpected selection)"
        fi
    else
        fail_test "$name (selector exited non-zero)"
    fi
}

# Runs the selector and expects success with the given text in stderr.
expect_selection_stderr() {
    local name="$1" pattern="$2"
    shift 2
    if "$SELECT" "$@" >/dev/null 2>"$SEL/stderr.txt" && grep -q "$pattern" "$SEL/stderr.txt"; then
        pass "$name"
    else
        fail_test "$name (expected stderr matching: $pattern)"
    fi
}

# Runs the selector and expects a fail-closed refusal with the given text.
expect_selection_refusal() {
    local name="$1" pattern="$2"
    shift 2
    if "$SELECT" "$@" >"$SEL/stdout.txt" 2>"$SEL/stderr.txt"; then
        fail_test "$name (expected a non-zero exit)"
    elif grep -q "$pattern" "$SEL/stderr.txt"; then
        if [ -s "$SEL/stdout.txt" ]; then
            fail_test "$name (refused but still printed candidates)"
        else
            pass "$name"
        fi
    else
        fail_test "$name (expected stderr matching: $pattern)"
    fi
}

FIXED_ARGS=(--releases "$SEL/releases.tsv" --published "$SEL/published.txt" --floor 0.1.7-rc.2 --today 2026-10-11)

expect_selection "selects the oldest unpublished version above the floor, in order" \
    "$(printf '0.2.0-rc.2\n0.2.1-alpha.1\n0.2.1-alpha.2')" "${FIXED_ARGS[@]}"
expect_selection "skips a listed version and keeps the rest in order" \
    "$(printf '0.2.1-alpha.1\n0.2.1-alpha.2')" "${FIXED_ARGS[@]}" --skips "$SEL/skips-one.txt"
expect_selection_stderr "reports why the version was skipped" \
    "skipping 0.2.0-rc.2 until 2027-01-31 — upstream dependency graph cannot boot" \
    "${FIXED_ARGS[@]}" --skips "$SEL/skips-one.txt"
expect_selection "skips several consecutive versions" \
    "0.2.1-alpha.2" "${FIXED_ARGS[@]}" --skips "$SEL/skips-consecutive.txt"
expect_selection "puts an expired skip back at the head of the candidate list" \
    "$(printf '0.2.0-rc.2\n0.2.1-alpha.1\n0.2.1-alpha.2')" "${FIXED_ARGS[@]}" --skips "$SEL/skips-expired.txt"
expect_selection_stderr "says that the skip expired and the version is retried" \
    "the skip recorded for 0.2.0-rc.2 expired on 2026-01-01" \
    "${FIXED_ARGS[@]}" --skips "$SEL/skips-expired.txt"
expect_selection_stderr "says how many versions stay queued behind the first candidate" \
    "the other 2 stay queued behind it" "${FIXED_ARGS[@]}"
expect_selection "selects nothing when every candidate is skipped" \
    "" "${FIXED_ARGS[@]}" --skips "$SEL/skips-all.txt"
expect_selection_stderr "says out loud that everything is skip-listed" \
    "every candidate is skip-listed" "${FIXED_ARGS[@]}" --skips "$SEL/skips-all.txt"
expect_selection "never re-emits a version that already has a release" \
    "$(printf '0.2.0-rc.2\n0.2.1-alpha.1\n0.2.1-alpha.2')" "${FIXED_ARGS[@]}"
expect_selection_stderr "explains that an existing release was skipped" \
    "runtime-0.2.0-rc.1 already exists; skipping" "${FIXED_ARGS[@]}"
expect_selection "selects nothing when the floor is not in the upstream list" \
    "" --releases "$SEL/releases.tsv" --published "$SEL/published.txt" --floor 0.9.9 --today 2026-10-11
expect_selection_stderr "warns instead of guessing when the floor is missing" \
    "is not in the upstream release list" \
    --releases "$SEL/releases.tsv" --published "$SEL/published.txt" --floor 0.9.9 --today 2026-10-11
expect_selection_refusal "fails closed when a skip record has no until date" \
    "missing the mandatory until date" "${FIXED_ARGS[@]}" --skips "$SEL/skips-no-date.txt"
expect_selection_refusal "fails closed when a skip record has no reason" \
    "missing a reason" "${FIXED_ARGS[@]}" --skips "$SEL/skips-no-reason.txt"
expect_selection_refusal "fails closed on an impossible date" \
    "until must be YYYY-MM-DD" "${FIXED_ARGS[@]}" --skips "$SEL/skips-bad-date.txt"
expect_selection_refusal "fails closed on a version that is not an upstream version" \
    "not an upstream version" "${FIXED_ARGS[@]}" --skips "$SEL/skips-bad-version.txt"
expect_selection_refusal "fails closed on a malformed upstream release list" \
    "unexpected upstream tag" --releases "$SEL/skips-one.txt" --published "$SEL/published.txt" \
    --floor 0.1.7-rc.2 --today 2026-10-11
# A skip list only removes candidates; it cannot move the Catalog backwards,
# because that decision stays in the precedent guard.
expect_failure_matching "an older version selected as a candidate is still refused by the precedent guard" \
    "refusing to publish" \
    "$SCRIPT_DIR/check-catalog-precedent.sh" "$WORK_DIR/v1/catalog.json" "$WORK_DIR/rc1/catalog.json"

echo "dependency audit"
mkdir -p "$WORK_DIR/audit"
cat > "$WORK_DIR/audit/allowlisted.json" <<'JSON'
{
  "lockfileVersion": 3,
  "packages": {
    "": { "dependencies": { "node-pty": "1.2.0-beta.15" } },
    "node_modules/node-pty": { "version": "1.2.0-beta.15", "hasInstallScript": true },
    "node_modules/protobufjs": { "version": "7.6.6", "hasInstallScript": true },
    "node_modules/@deepseek-ai/dsh-subprocess-local": { "version": "0.2.0-rc.2", "hasInstallScript": true }
  }
}
JSON
expect_success "accepts a graph whose install scripts are all accounted for" \
    node "$SCRIPT_DIR/audit-dependencies.js" "$WORK_DIR/audit/allowlisted.json"

cat > "$WORK_DIR/audit/unexpected-script.json" <<'JSON'
{
  "lockfileVersion": 3,
  "packages": {
    "": {},
    "node_modules/node-pty": { "version": "1.2.0-beta.15", "hasInstallScript": true },
    "node_modules/some-new-native": { "version": "1.0.0", "hasInstallScript": true }
  }
}
JSON
expect_failure_matching "fails when a new package adds an install script the Runtime skips" \
    "declare an install script the Runtime does not run: some-new-native@1.0.0 (install script)" \
    node "$SCRIPT_DIR/audit-dependencies.js" "$WORK_DIR/audit/unexpected-script.json"

cat > "$WORK_DIR/audit/unexpected-gyp.json" <<'JSON'
{
  "lockfileVersion": 3,
  "packages": {
    "": {},
    "node_modules/some-native-addon": { "version": "2.0.0", "gypfile": true }
  }
}
JSON
expect_failure_matching "fails when a new package needs a native build the Runtime skips" \
    "some-native-addon@2.0.0 (native build)" \
    node "$SCRIPT_DIR/audit-dependencies.js" "$WORK_DIR/audit/unexpected-gyp.json"

cat > "$WORK_DIR/audit/no-scripts.json" <<'JSON'
{
  "lockfileVersion": 3,
  "packages": {
    "": {},
    "node_modules/left-pad": { "version": "1.3.0" }
  }
}
JSON
expect_success_matching "notes every allowlist entry that left the dependency graph" \
    "protobufjs is allowlisted but no longer in the dependency graph" \
    node "$SCRIPT_DIR/audit-dependencies.js" "$WORK_DIR/audit/no-scripts.json"

echo "process cleanup"
# A leaked child is a real process, so these scenarios start real process trees
# and watch what the shared helpers do to them.
PROCESS_SCENARIOS="$SCRIPT_DIR/tests/process-tree-scenarios.sh"
expect_success "records the descendant tree of a running process" \
    "$PROCESS_SCENARIOS" records
expect_success "reports a child that outlives its parent as a leak" \
    "$PROCESS_SCENARIOS" detects-leak
expect_success "stops the recorded descendants of a leaked tree" \
    "$PROCESS_SCENARIOS" cleans-leak
expect_success "escalates to SIGKILL for a descendant that ignores SIGTERM" \
    "$PROCESS_SCENARIOS" escalates
expect_success "stays best-effort when a recorded process already exited" \
    "$PROCESS_SCENARIOS" best-effort
expect_success "never signals a process it did not record" \
    "$PROCESS_SCENARIOS" leaves-unrelated-alone
expect_success "refuses to signal its own shell or an unrelated PID" \
    "$PROCESS_SCENARIOS" protects-itself

echo "plugin market pin"
expect_success "range semantics match DSH Studio's PluginCompatibility" \
    node -e '
const assert = require("assert");
const { satisfies } = require(process.argv[1]);
const legacy = "^0.1.0-rc.7 || ^0.1.1-rc.2 || ^0.1.2-alpha.2";
const current = `${legacy} || ^0.2.0-rc.1`;
// The production failure: the market that listed 0.1.x only, and the Runtime that moved to 0.2.
assert.strictEqual(satisfies("0.2.0-rc.1", legacy), false);
assert.strictEqual(satisfies("0.1.7-rc.2", legacy), true);
assert.strictEqual(satisfies("0.1.0-rc.6", legacy), false);
assert.strictEqual(satisfies("0.2.0-rc.1", current), true);
assert.strictEqual(satisfies("0.1.7-rc.2", current), true);
assert.strictEqual(satisfies("0.3.0-rc.1", current), false);
// Prereleases are judged on their line, except when the range names that build.
assert.strictEqual(satisfies("0.1.6-alpha.2", "^0.1.0-rc.7"), true);
assert.strictEqual(satisfies("0.1.0-rc.6", "^0.1.0-rc.7"), false);
assert.strictEqual(satisfies("0.2.0-rc.1", "^0.2.0-rc.1"), true);
assert.strictEqual(satisfies("0.2.0-beta.1", "^0.2.0-rc.1"), false);
assert.strictEqual(satisfies("0.2.0", "^0.2.0-rc.1"), true);
assert.strictEqual(satisfies("0.2.0-rc.1", "^0.1.2-alpha.2"), false);
// Operators.
assert.strictEqual(satisfies("0.1.5", "~0.1.2"), true);
assert.strictEqual(satisfies("0.2.0", "~0.1.2"), false);
assert.strictEqual(satisfies("1.2.3", "^1.2.3"), true);
assert.strictEqual(satisfies("2.0.0", "^1.2.3"), false);
assert.strictEqual(satisfies("0.3.0", "0.0.3"), false);
assert.strictEqual(satisfies("0.0.30", ">=0.0.3 <0.0.4"), false);
assert.strictEqual(satisfies("0.1.5", ">=0.1.2 <0.2.0"), true);
assert.strictEqual(satisfies("0.2.0", ">=0.1.2 <0.2.0"), false);
assert.strictEqual(satisfies("0.2.0-rc.1", "0.2.0-rc.1"), true);
assert.strictEqual(satisfies("0.2.0", "0.2.0-rc.1"), false);
assert.strictEqual(satisfies("1.2.3+build.5", "^1.2.3"), true);
// Unreadable ranges are undecidable, never a verdict.
assert.strictEqual(satisfies("0.2.0-rc.1", "latest"), null);
assert.strictEqual(satisfies("0.2.0-rc.1", "^0.2.0 || "), null);
assert.strictEqual(satisfies("0.2.0-rc.1", "^abc"), null);
assert.strictEqual(satisfies("0.2.0-rc.1", "^0.2.0, <0.3.0"), null);
assert.strictEqual(satisfies("not-a-version", "^0.2.0"), null);
' "$SCRIPT_DIR/resolve-plugin-market.js"

expect_success "pin selection takes the newest compatible released version" \
    node -e '
const assert = require("assert");
const { selectPin } = require(process.argv[1]);
const legacy = "^0.1.0-rc.7 || ^0.1.1-rc.2 || ^0.1.2-alpha.2";
const candidates = [
  { version: "1.62.0", integrity: "sha512-old", harnessRange: legacy },
  { version: "1.66.5", integrity: "sha512-pin", harnessRange: `${legacy} || ^0.2.0-rc.1` },
  { version: "1.70.0", integrity: "sha512-new", harnessRange: "^0.3.0" },
  { version: "1.71.0-beta.1", integrity: "sha512-beta", harnessRange: "^0.2.0" },
  { version: "1.72.0", integrity: "", harnessRange: "^0.2.0" },
  { version: "1.73.0", integrity: "sha512-norange", harnessRange: null },
  { version: "1.74.0", integrity: "sha512-unreadable", harnessRange: "works-with-everything" }
];
assert.strictEqual(selectPin(candidates, "0.2.0-rc.1").version, "1.66.5");
assert.strictEqual(selectPin(candidates, "0.1.7-rc.2").version, "1.66.5");
// A prerelease is only chosen when no released version covers the Harness.
assert.strictEqual(selectPin([candidates[3]], "0.2.0-rc.1").version, "1.71.0-beta.1");
assert.throws(() => selectPin(candidates, "9.9.9"), /no dshmarket version declares support/);
' "$SCRIPT_DIR/resolve-plugin-market.js"

expect_success "declared Harness range prefers the package the market names" \
    node -e '
const assert = require("assert");
const { declaredHarnessRange } = require(process.argv[1]);
assert.strictEqual(declaredHarnessRange({
  peerDependencies: { "@deepseek-ai/dsh": "^1.0.0", "@deepseek-ai/dsh-settings": "^0.2.0" }
}), "^0.2.0");
assert.strictEqual(declaredHarnessRange({ peerDependencies: { "@deepseek-ai/dsh": "^1.0.0" } }), "^1.0.0");
assert.strictEqual(declaredHarnessRange({ peerDependencies: {} }), null);
assert.strictEqual(declaredHarnessRange({}), null);
' "$SCRIPT_DIR/resolve-plugin-market.js"

echo "runtime-smoke.sh detects broken artifacts"
make_fake_runtime "$WORK_DIR/fake-ok"
rm "$WORK_DIR/fake-ok/manifest.json"
expect_failure "refuses a Runtime without a manifest" \
    "$SCRIPT_DIR/runtime-smoke.sh" "$WORK_DIR/fake-ok"

make_fake_runtime "$WORK_DIR/fake-no-node"
rm "$WORK_DIR/fake-no-node/node/darwin-arm64/bin/node"
expect_failure "refuses a Runtime without its Node binary" \
    "$SCRIPT_DIR/runtime-smoke.sh" "$WORK_DIR/fake-no-node"

make_fake_runtime "$WORK_DIR/fake-no-pty"
rm -rf "$WORK_DIR/fake-no-pty/harness/darwin-arm64/0.1.1-rc.2/node_modules/node-pty"
expect_failure "refuses a Runtime without node-pty" \
    "$SCRIPT_DIR/runtime-smoke.sh" "$WORK_DIR/fake-no-pty"

make_fake_runtime "$WORK_DIR/fake-no-version"
edit_json "$WORK_DIR/fake-no-version/manifest.json" 'delete value.nodeVersion'
expect_failure "refuses a manifest without a Node version" \
    "$SCRIPT_DIR/runtime-smoke.sh" "$WORK_DIR/fake-no-version"

make_fake_runtime "$WORK_DIR/fake-wrong-path"
mv "$WORK_DIR/fake-wrong-path/node/darwin-arm64" "$WORK_DIR/fake-wrong-path/node/darwin-arm65"
expect_failure "refuses a Runtime whose layout does not match its architecture" \
    "$SCRIPT_DIR/runtime-smoke.sh" "$WORK_DIR/fake-wrong-path"

make_fake_runtime "$WORK_DIR/fake-mislabelled"
edit_json "$WORK_DIR/fake-mislabelled/manifest.json" 'value.architecture = "darwin-x64"'
expect_failure "refuses a manifest that mislabels the architecture" \
    "$SCRIPT_DIR/runtime-smoke.sh" "$WORK_DIR/fake-mislabelled"

make_fake_runtime "$WORK_DIR/fake-no-seam"
rm -rf "$WORK_DIR/fake-no-seam/harness/darwin-arm64/0.1.1-rc.2/node_modules/@deepseek-ai/dsh-sandbox-local"
expect_failure_matching "refuses a Runtime without the confinement seam" \
    "the confinement seam did not load with the packaged Node" \
    "$SCRIPT_DIR/runtime-smoke.sh" "$WORK_DIR/fake-no-seam"

make_fake_runtime "$WORK_DIR/fake-missing-mode"
printf 'export const SANDBOX_MODES = ["read-only", "danger-full-access"];\n' \
    > "$WORK_DIR/fake-missing-mode/harness/darwin-arm64/0.1.1-rc.2/node_modules/@deepseek-ai/dsh-sandbox-policy/lib/index.js"
expect_failure_matching "refuses a Runtime whose sandbox policy dropped a mode" \
    "dropped the workspace-write mode" \
    "$SCRIPT_DIR/runtime-smoke.sh" "$WORK_DIR/fake-missing-mode"

make_fake_runtime "$WORK_DIR/fake-unpinned-koffi"
mkdir -p "$WORK_DIR/fake-unpinned-koffi/harness/darwin-arm64/0.1.1-rc.2/node_modules/koffi" \
    "$WORK_DIR/fake-unpinned-koffi/harness/darwin-arm64/0.1.1-rc.2/node_modules/@deepseek-ai/dsh-fs-local"
printf '{"name":"koffi","version":"3.1.0"}\n' \
    > "$WORK_DIR/fake-unpinned-koffi/harness/darwin-arm64/0.1.1-rc.2/node_modules/koffi/package.json"
printf '{"name":"@deepseek-ai/dsh-fs-local","version":"0.1.1-rc.2","dependencies":{"koffi":"3.1.1"}}\n' \
    > "$WORK_DIR/fake-unpinned-koffi/harness/darwin-arm64/0.1.1-rc.2/node_modules/@deepseek-ai/dsh-fs-local/package.json"
expect_failure_matching "refuses a Runtime whose native FFI version moved off its pin" \
    "koffi 3.1.0 does not match the pinned 3.1.1" \
    "$SCRIPT_DIR/runtime-smoke.sh" "$WORK_DIR/fake-unpinned-koffi"

echo "trust anchor"
expect_success "keys/runtime-catalog-public.txt holds a usable Ed25519 key" \
    node -e '
const fs = require("fs");
const assert = require("assert");
const text = fs.readFileSync(process.argv[1], "utf8");
const keyID = (/^keyID=(.+)$/m.exec(text) || [])[1];
const publicKey = ((/^publicKey=(.+)$/m.exec(text) || [])[1] || "").trim();
assert.ok(keyID, "keyID is missing");
assert.strictEqual(Buffer.from(publicKey, "base64").length, 32, "publicKey must be 32 bytes of base64");
' "$REPOSITORY_ROOT/keys/runtime-catalog-public.txt"

echo "syntax checks"
for script in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR"/tests/*.sh; do
    expect_success "bash -n ${script#"$SCRIPT_DIR"/}" bash -n "$script"
done

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
