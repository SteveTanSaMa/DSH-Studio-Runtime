# Runtime catalog signing keys

DSH Studio only trusts a Runtime catalog that is signed by one specific Ed25519
key. That key exists in two halves, in two different repositories, and the two
halves **must always describe the same keypair**:

| Half | Where it lives | Purpose |
| --- | --- | --- |
| Private key | GitHub Actions secret `RUNTIME_CATALOG_PRIVATE_KEY_BASE64` in `SteveTanSaMa/DSH-Studio-Runtime` | Signs the catalog during release |
| Public key | `RUNTIME_CATALOG_PUBLIC_KEY` in the DSH Studio target of `DSH Studio.xcodeproj/project.pbxproj` (Debug **and** Release), surfaced through `Info.plist` | `RuntimeCatalogTrust` trust anchor |

Signing is supplied to the workflow as base64-encoded **PKCS#8 DER** bytes. The
workflow signs on every release; no local key is needed for routine work.

## The invariant

The base64 public key derived from the private key must equal the value in
`project.pbxproj`. If they diverge, the app rejects every catalog and remote
Runtime discovery silently stops working.

Check the current catalog against the app's trust anchor:

```sh
cat > /tmp/check.js <<'JS'
const crypto = require("crypto"), fs = require("fs");
const env = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const spki = Buffer.concat([
  Buffer.from("302a300506032b6570032100", "hex"),
  Buffer.from(process.argv[3], "base64"),
]);
const key = crypto.createPublicKey({ key: spki, format: "der", type: "spki" });
console.log(crypto.verify(null, Buffer.from(env.payload, "base64"), key,
                          Buffer.from(env.signature, "base64")));
JS

curl -sL -o /tmp/catalog.json \
  https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-catalog/runtime-catalog.signed.json

node /tmp/check.js /tmp/catalog.json "$(grep -m1 RUNTIME_CATALOG_PUBLIC_KEY \
  "DSH Studio.xcodeproj/project.pbxproj" | sed 's/.*= "//; s/";//')"
```

Any rotation must also confirm `keyID` still equals
`RuntimeCatalogTrust.keyID` (`runtime-catalog-v1`); changing the key material
alone does not require changing the key ID.

## Rotating the key

1. Generate a new Ed25519 keypair and store the private key as PKCS#8 DER,
   base64-encoded:

   ```sh
   node -e '
   const c = require("crypto");
   const { privateKey } = c.generateKeyPairSync("ed25519");
   const der = privateKey.export({ format: "der", type: "pkcs8" });
   console.log("RUNTIME_CATALOG_PRIVATE_KEY_BASE64=" + der.toString("base64"));
   console.log("RUNTIME_CATALOG_PUBLIC_KEY=" +
     c.createPublicKey(privateKey).export({ format: "der", type: "spki" })
      .subarray(-32).toString("base64"));
   '
   ```

2. Update the secret in `DSH-Studio-Runtime`.
3. Update `RUNTIME_CATALOG_PUBLIC_KEY` for **both** Debug and Release in the
   DSH Studio target, then ship a new app build.
4. Publish a catalog with the new key, and verify the signature with the command
   above before releasing the app.

Keep an offline backup of the private key. GitHub secrets cannot be read back, so
a lost private key cannot be recovered — the only fix is a full rotation.

## Retired keys

Superseded keypairs are kept, clearly marked, under
`~/.config/dsh-studio/retired/` on the build machine. They must never be used to
sign a catalog.
