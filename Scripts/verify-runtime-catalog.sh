#!/usr/bin/env bash
set -euo pipefail

# Verifies a signed Runtime catalog envelope and writes its decoded payload.
#
# Usage: verify-runtime-catalog.sh SIGNED_JSON PUBLIC_KEY_BASE64 [PAYLOAD_OUT]
#
# The expected key ID is *not* a positional argument: it comes from the
# environment variable RUNTIME_CATALOG_KEY_ID and defaults to runtime-catalog-v1.
# Set it to check an envelope signed under a different key ID.
#
# The public key is the base64-encoded raw Ed25519 key that DSH Studio embeds as
# its trust anchor (keys/runtime-catalog-public.txt). Every check fails closed:
# an unreadable envelope, an unexpected schema version or key ID, a key of the
# wrong length and an invalid signature all exit non-zero, so this can gate a
# release.

SIGNED_PATH="${1:-}"
PUBLIC_KEY_BASE64="${2:-${RUNTIME_CATALOG_PUBLIC_KEY:-}}"
PAYLOAD_PATH="${3:-}"
KEY_ID="${RUNTIME_CATALOG_KEY_ID:-runtime-catalog-v1}"

die() {
    printf 'verify-runtime-catalog: %s\n' "$1" >&2
    exit 1
}

[ -n "$SIGNED_PATH" ] || die "usage: $0 SIGNED_JSON PUBLIC_KEY_BASE64 [PAYLOAD_OUT]"
[ -f "$SIGNED_PATH" ] || die "signed catalog does not exist: $SIGNED_PATH"
[ -n "$PUBLIC_KEY_BASE64" ] || die "a base64 Ed25519 public key is required (second argument or RUNTIME_CATALOG_PUBLIC_KEY)"
command -v node >/dev/null 2>&1 || die "missing required command: node"

node - "$SIGNED_PATH" "$PUBLIC_KEY_BASE64" "$KEY_ID" "$PAYLOAD_PATH" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");

// The trust anchor is the raw 32-byte Ed25519 public key, so wrap it in a
// SubjectPublicKeyInfo header before handing it to Node.
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function verify(signedPath, publicKeyBase64, expectedKeyID, payloadPath) {
  const publicKeyBytes = Buffer.from(publicKeyBase64.trim(), "base64");
  if (publicKeyBytes.length !== 32) {
    throw new Error("the trust anchor must be a base64-encoded 32-byte Ed25519 public key");
  }

  const envelope = JSON.parse(fs.readFileSync(signedPath, "utf8"));
  if (envelope.schemaVersion !== 1) {
    throw new Error(`unsupported envelope schema version: ${envelope.schemaVersion}`);
  }
  if (envelope.keyID !== expectedKeyID) {
    throw new Error(`unexpected key ID: ${envelope.keyID} (expected ${expectedKeyID})`);
  }
  if (typeof envelope.payload !== "string" || typeof envelope.signature !== "string") {
    throw new Error("the envelope is missing its payload or signature");
  }

  const payload = Buffer.from(envelope.payload, "base64");
  const signature = Buffer.from(envelope.signature, "base64");
  const publicKey = crypto.createPublicKey({
    key: Buffer.concat([SPKI_PREFIX, publicKeyBytes]),
    format: "der",
    type: "spki"
  });
  if (!crypto.verify(null, payload, publicKey, signature)) {
    throw new Error("the catalog signature is invalid");
  }

  const catalog = JSON.parse(payload.toString("utf8"));
  if (catalog.schemaVersion !== 1) {
    throw new Error(`unsupported catalog schema version: ${catalog.schemaVersion}`);
  }
  if (typeof catalog.runtimeVersion !== "string" || !Array.isArray(catalog.releases)) {
    throw new Error("the signed payload is not a Runtime catalog");
  }

  if (payloadPath) {
    fs.writeFileSync(payloadPath, payload);
  }
  process.stdout.write(
    `Runtime catalog verified: ${catalog.runtimeVersion} (${catalog.releases.length} releases)\n`);
}

const [signedPath, publicKeyBase64, expectedKeyID, payloadPath] = process.argv.slice(2);
try {
  verify(signedPath, publicKeyBase64, expectedKeyID, payloadPath);
} catch (error) {
  process.stderr.write(`verify-runtime-catalog: ${error.message}\n`);
  process.exit(1);
}
NODE
