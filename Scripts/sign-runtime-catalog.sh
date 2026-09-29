#!/usr/bin/env bash
set -euo pipefail

# Signs an immutable Runtime catalog with an Ed25519 private key.
#
# The private key comes from CI (or a local secret store), is never written to
# the repository and is deliberately kept out of the command line: unlike argv,
# the environment is not world-readable through ps. DSH Studio verifies the
# resulting envelope with the public key embedded in the app, so signing also
# asserts that the key in use is the one shipped clients trust: a rotation that
# only updated the secret would otherwise disable remote Runtime discovery for
# every released app, silently.
#
# Usage: RUNTIME_CATALOG_PRIVATE_KEY_BASE64=... RUNTIME_CATALOG_PUBLIC_KEY=... \
#            $0 CATALOG_JSON OUTPUT_SIGNED_JSON

INPUT_PATH="${1:-}"
OUTPUT_PATH="${2:-}"
PRIVATE_KEY_PATH="${RUNTIME_CATALOG_PRIVATE_KEY_PATH:-}"
PRIVATE_KEY_BASE64="${RUNTIME_CATALOG_PRIVATE_KEY_BASE64:-}"
PUBLIC_KEY_BASE64="${RUNTIME_CATALOG_PUBLIC_KEY:-}"
KEY_ID="${RUNTIME_CATALOG_KEY_ID:-runtime-catalog-v1}"

export RUNTIME_CATALOG_PRIVATE_KEY_PATH RUNTIME_CATALOG_PRIVATE_KEY_BASE64
export RUNTIME_CATALOG_PUBLIC_KEY

die() {
    printf 'sign-runtime-catalog: %s\n' "$1" >&2
    exit 1
}

[ -f "$INPUT_PATH" ] || die "catalog input does not exist: $INPUT_PATH"
[ -n "$OUTPUT_PATH" ] || die "usage: $0 CATALOG_JSON OUTPUT_SIGNED_JSON"
if [ -n "$PRIVATE_KEY_PATH" ] && [ -n "$PRIVATE_KEY_BASE64" ]; then
    die "set either RUNTIME_CATALOG_PRIVATE_KEY_PATH or RUNTIME_CATALOG_PRIVATE_KEY_BASE64, not both"
fi
[ -n "$PRIVATE_KEY_PATH" ] || [ -n "$PRIVATE_KEY_BASE64" ] || die \
    "set RUNTIME_CATALOG_PRIVATE_KEY_PATH or RUNTIME_CATALOG_PRIVATE_KEY_BASE64"
[ -n "$PUBLIC_KEY_BASE64" ] || die \
    "RUNTIME_CATALOG_PUBLIC_KEY must carry the trust anchor embedded in DSH Studio (see keys/runtime-catalog-public.txt)"
command -v node >/dev/null 2>&1 || die "missing required command: node"

mkdir -p "$(dirname "$OUTPUT_PATH")"
node - "$INPUT_PATH" "$OUTPUT_PATH" "$KEY_ID" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");

const [inputPath, outputPath, keyID] = process.argv.slice(2);

function sign() {
  const privateKeyBase64 = process.env.RUNTIME_CATALOG_PRIVATE_KEY_BASE64;
  const privateKeyPath = process.env.RUNTIME_CATALOG_PRIVATE_KEY_PATH;
  const keyMaterial = privateKeyBase64
    ? Buffer.from(privateKeyBase64, "base64")
    : fs.readFileSync(privateKeyPath);
  const privateKey = privateKeyBase64
    ? crypto.createPrivateKey({ key: keyMaterial, format: "der", type: "pkcs8" })
    : crypto.createPrivateKey(keyMaterial);

  const derivedPublicKey = crypto
    .createPublicKey(privateKey)
    .export({ format: "der", type: "spki" })
    .subarray(-32);
  const expectedPublicKey = Buffer.from(process.env.RUNTIME_CATALOG_PUBLIC_KEY.trim(), "base64");
  if (expectedPublicKey.length !== 32) {
    throw new Error("RUNTIME_CATALOG_PUBLIC_KEY must be a base64-encoded 32-byte Ed25519 public key");
  }
  if (!derivedPublicKey.equals(expectedPublicKey)) {
    throw new Error(
      "the signing key does not match the published trust anchor " +
      `(derived ${derivedPublicKey.toString("base64")}, expected ${expectedPublicKey.toString("base64")})`);
  }

  const payload = fs.readFileSync(inputPath);
  const signature = crypto.sign(null, payload, privateKey);
  fs.writeFileSync(outputPath, JSON.stringify({
    schemaVersion: 1,
    keyID,
    payload: payload.toString("base64"),
    signature: signature.toString("base64")
  }, null, 2) + "\n");

  return derivedPublicKey.toString("base64");
}

try {
  const derivedPublicKey = sign();
  process.stdout.write(`Runtime catalog signed: ${outputPath}\n`);
  process.stdout.write(`Runtime catalog public key (base64): ${derivedPublicKey}\n`);
} catch (error) {
  process.stderr.write(`sign-runtime-catalog: ${error.message}\n`);
  process.exit(1);
}
NODE
