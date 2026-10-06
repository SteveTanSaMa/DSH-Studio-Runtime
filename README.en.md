# DSH Studio Runtime

**English** | [中文](README.md)

This repository packages the official DeepSeek Harness and its complete dependency set into
**verifiable, immutable, rollback-capable** macOS Runtime artifacts, and publishes them through a
signed catalog. The client repository
[DSH Studio](https://github.com/SteveTanSaMa/DSH-Studio) only performs Runtime discovery, signature
verification, download, validation, installation, health checks, and rollback.

**Scope**

- This repository does not implement Harness and contains no App/UI code; the official Harness is a
  dependency, not a fork.
- This repository does not run an update service; clients read static assets from GitHub Releases.
- This repository keeps no copy of published artifacts; GitHub Releases are the only distribution
  channel.

**Normative wording**: in this document, "MUST" means a violation fails closed, "MUST NOT" means the
corresponding operation is rejected by the tooling or the pipeline, and "SHOULD" marks a convention
that needs justification when deviated from.

## Table of Contents

- [1. Pipeline](#1-pipeline)
- [2. Version identity](#2-version-identity)
- [3. Artifacts and naming](#3-artifacts-and-naming)
- [4. Releases](#4-releases)
- [5. Signing and keys](#5-signing-and-keys)
- [6. Repository configuration](#6-repository-configuration)
- [7. Local build](#7-local-build)
- [8. Verification and tests](#8-verification-and-tests)
- [9. How DSH Studio consumes the catalog](#9-how-dsh-studio-consumes-the-catalog)
- [10. Known limitations](#10-known-limitations)
- [11. Documentation index](#11-documentation-index)

## 1. Pipeline

```text
DeepSeek Harness (upstream release tag dsh-v<version> / npm @deepseek-ai/dsh@<version>)
        │ exactly pinned version
        ▼
DSH-Studio-Runtime
        ├── build       download the pinned Node, resolve Harness and pnpm dependencies
        ├── package     produce an archive: manifest.json + node/ + harness/
        ├── smoke test  start Harness on the extracted artifact and exercise native dependencies
        ├── checksum    compute the artifact's SHA-256
        └── sign        sign the catalog with Ed25519
        │
        ▼
Signed catalog (runtime-catalog.signed.json in the `runtime-catalog` release)
        │
        ▼
DSH Studio: verify signature → verify SHA-256 → validate archive → install → health check → roll back on failure
```

## 2. Version identity

The authoritative rules live in [`docs/versioning.md`](docs/versioning.md) (Chinese). Summary:

```text
DeepSeek Harness 0.2.0-rc.1
        │
        ▼
Runtime 0.2.0-rc.1      ← version number = Harness version (tag / title / filename / manifest / catalog)
        │
        ▼
SHA-256                 ← artifact identity: repacking changes this value, not the version number
```

| Name | Meaning | Where it appears |
| --- | --- | --- |
| `runtimeVersion` | The official Harness version (for example `0.2.0-rc.1`); the Runtime's only version identity | tag, title, filenames, manifest, catalog |
| `platform` / `architecture` | `macos` / `darwin-arm64`, `darwin-x64` | manifest, catalog |
| `sha256` | Byte identity of the final artifact | `artifact-*.json`, signed catalog, release assets |
| `provenance` | Build origin (commit, run id), used for traceability only | release body, manifest |

### Invariants

1. `runtimeVersion` MUST equal the official Harness version; a build counter (`-verN`, `-rN`,
   `-rebuild-N`, `-revision-N`) is rejected by both the build script and the catalog generator.
2. One `runtimeVersion` corresponds to exactly one current Runtime. A repack keeps the version number,
   tag, and filenames, replaces the assets, and updates the `sha256` recorded in the catalog.
3. Artifact identity is the `sha256` and `size` recorded in the catalog; clients verify every byte
   after downloading and refuse to install on mismatch.
4. The shape of the tag, asset names, and download URLs MUST match the client contract
   (`docs/runtime-contract.md`, sections 1 and 2); changing them makes released apps reject the
   catalog.

### Ordering

Versions are compared by parsing semver, never as strings:
`0.2.0-rc.9 < 0.2.0-rc.10 < 0.2.0 < 0.2.1`. The client's `RuntimeVersionOrdering.compare` and this
repository's `Scripts/check-catalog-precedent.sh` MUST implement the same semantics, so the publisher
and the client never disagree about which Runtime is newer.

### Display and diagnostics

The only user-visible version is the Harness version. Build details (commit, run id) are written into
the release body and the manifest's `provenance`; they never appear as part of a version string.

### Historical form (retired)

The repository previously used `<harnessVersion>-verN` for the Nth packaging of the same Harness
version. That form is retired:

- the publishing side no longer accepts it: both `Scripts/build-runtime.sh` and
  `Scripts/generate-runtime-catalog.sh` reject a version that carries a build counter;
- every `-verN` release and catalog has been removed, so no artifact of that form exists;
- `Scripts/check-catalog-precedent.sh` keeps no parsing branch for it: a Runtime version is a Harness
  version and is compared by the ordering rules in section 2.

## 3. Artifacts and naming

### Naming

| Object | Rule | Example |
| --- | --- | --- |
| Runtime release tag | `runtime-<runtimeVersion>` | `runtime-0.2.0-rc.2` |
| Runtime release title | `Runtime <runtimeVersion>` | `Runtime 0.2.0-rc.2` |
| Architecture artifact | `dsh-runtime-<runtimeVersion>-<architecture>.tar.gz` | `dsh-runtime-0.2.0-rc.2-darwin-arm64.tar.gz` |
| Installation manifest asset | `manifest-<runtimeVersion>-<architecture>.json` | — |
| Artifact metadata | `artifact-<runtimeVersion>-<architecture>.json` | — |
| Unsigned catalog payload | `runtime-release.json` | — |
| Catalog release | tag `runtime-catalog`, asset `runtime-catalog.signed.json` | — |

The Runtime produces no additional `*.tar.gz.sha256` files: the release page shows each asset's
SHA-256, and the metadata and signed catalog also record it for automatic client verification.

### Archive layout

Only the following entries are permitted at the archive root; any other entry (including macOS
`.DS_Store` and AppleDouble `._*` files) makes the client reject the whole artifact:

```text
manifest.json
node/<architecture>/...
harness/<architecture>/<harnessVersion>/...
```

### Manifest (inside the archive, `schemaVersion: 3`)

`schemaVersion`, `runtimeVersion`, `platform`, `architecture`, `nodeVersion`, `harnessVersion`,
`pnpmVersion`, `nodeSHA256`, `harnessPackageIntegrity`, `pnpmPackageIntegrity`, `registry`,
`dependencyLockSHA256`, `pluginMarket`, `dataFormat`, `provenance`.

The client compares these fields, one by one, against the matching entry in the signed catalog.
Adding fields is compatible (unknown fields are ignored); changing or removing the meaning of an
existing field is not. The artifact's own `sha256`/`size` are deliberately absent from the archive —
the manifest is part of the archive, so recording its own digest there would be circular; they are
carried by the metadata and the signed catalog instead.

### Catalog (signed payload, `schemaVersion: 1`)

`runtimeVersion`, plus exactly one `releases[]` entry per architecture carrying `runtimeVersion`,
`platform`, `architecture`, `nodeVersion`, `harnessVersion`, `pnpmVersion`, `nodeArchiveSHA256`,
`harnessPackageIntegrity`, `pnpmPackageIntegrity`, `dependencyLockSHA256`, `pluginMarket`,
`dataFormat`, and `artifact` (`runtimeVersion`, `architecture`, `url`, `sha256`, `size`).

### Signature envelope (`schemaVersion: 1`)

```json
{
  "schemaVersion": 1,
  "keyID": "runtime-catalog-v1",
  "payload": "<base64-encoded catalog JSON>",
  "signature": "<base64-encoded Ed25519 signature over the raw payload bytes>"
}
```

## 4. Releases

### Triggers

| Trigger | Behaviour |
| --- | --- |
| `workflow_dispatch` | Enter a Harness version (for example `0.2.0-rc.1`). Entering an already published version repacks it and replaces its assets |
| `runtime-<version>` tag push | Equivalent to a dispatch; the `runtime-catalog` tag is explicitly excluded so it cannot trigger itself |
| Hourly cron | Walks upstream `dsh-v*` releases in publication order: versions whose `runtime-<version>` release exists are skipped; versions whose `@deepseek-ai/dsh@<version>` is not on npm are skipped with a warning; otherwise it builds that version and ends the run (at most one version per run) |

`UPSTREAM_MIN_HARNESS_VERSION` (currently `0.1.7-rc.2`) and everything before it count as already
handled, so polling starts at `0.2.0-rc.1`. That floor MUST stay on the last unrebuildable version:
moving it forward would make the poll retry a version that can never build and never reach a newer
one (see [`docs/historical-versions.md`](docs/historical-versions.md)).

### Pipeline order

```text
resolve exact Harness version
        ▼
build (once per architecture)
        ▼
audit dependencies (a new install / native build script in the closure → fail)
        ▼
generate manifest (platform / dependencyLockSHA256 / provenance / pluginMarket / dataFormat)
        ▼
package + SHA-256
        ▼
smoke test (on the extracted artifact)
        ▼
generate catalog (re-verify artifact bytes, size and checksum)
        ▼
check precedent (refuse downgrades; report same-version repacks)
        ▼
sign catalog (Ed25519, must match the trust anchor)
        ▼
upload artifacts → upload signed catalog (the catalog goes last)
        ▼
verify-published (re-download from public URLs, verify signature and SHA-256)
```

A failure at any step produces no new usable catalog.

### Refusal conditions (fail closed)

| Condition | Result |
| --- | --- |
| `RUNTIME_VERSION` is not a valid Harness version, or carries a build counter | build fails |
| `PNPM_VERSION` is missing | build fails |
| The Node archive does not match its official `SHASUMS256.txt` | build fails |
| No plugin market version declares support for the Harness version | build fails (unless `none` is explicit, see section 7) |
| The dependency closure gains an unrecorded install / native build script | build fails |
| Any smoke test assertion fails | build fails |
| Artifact bytes do not match their metadata's `sha256`/`size` | catalog generation fails |
| The already published catalog does not verify | release fails |
| The new catalog is older than the published one | release fails (unless `allow_catalog_downgrade` is explicit) |
| The private key does not derive the public key in `keys/runtime-catalog-public.txt` | signing fails |

### Failure handling

- The publish job records whether the current run created the release. If it fails before the catalog
  upload completes, the run deletes the release and tag **it created**, so a later cron run or dispatch
  can rebuild that version; a failure before the release exists deletes nothing.
- Once the catalog upload completes the version counts as published: later steps failing does not roll
  it back.
- Manual intervention (for example to discard a version):

  ```bash
  gh release delete runtime-0.2.0-rc.1 --repo SteveTanSaMa/DSH-Studio-Runtime --yes --cleanup-tag
  ```

  Then dispatch again or wait for the cron. To keep the release and only replace assets and catalog,
  dispatch the same version again.

- Assets are uploaded one at a time, so there is a window in which the new tarball is published while
  the catalog still records the old one. A client verifying the new bytes against a cached catalog
  fails closed and does not install anything during that window.

- If a run is interrupted after creating the `runtime-catalog` release but before uploading the
  catalog, the release exists without its asset. That state does not block later runs: the next
  publish treats it as "no published catalog asset yet" and writes a signed catalog, repairing it.
  Verification is not weakened — an asset that exists but does not verify is still refused.
- After each release the pipeline marks `runtime-catalog` as GitHub's **Latest** again; otherwise the
  badge moves to the new version and pushes the client's entry point down the list. The operation only
  affects the badge and never touches assets.

### Update safety (client semantics)

DSH Studio updates a Runtime in this order:

```text
download → verify (signature + SHA-256 + size) → extract → validate (manifest matches the catalog)
        → launch → health check (settings/describe) → activate
```

**Activate must be the last step**: if `download`, `verify`, `extract`, `validate`, `launch` or the
`health check` fails, the new Runtime is discarded and the known-good Runtime stays exactly as it was.

This repository is not the installer: installing, promoting and rolling back are implemented in DSH
Studio. What this repository owes those semantics is the publishing side — it only publishes bytes that
were verified against the signed catalog (whose `sha256` is the artifact identity), a same-version
repack replaces release assets without ever asking a client to delete an existing Runtime, and the
catalog never regresses. Fault injection for the install/rollback stages therefore belongs in the app;
everything this repository can prove about failures (checksum mismatch, corrupt archive, manifest that
contradicts the layout, catalog downgrade, leaked process trees) lives in `Scripts/run-tests.sh` and
`Scripts/runtime-smoke.sh`, see section 8.

## 5. Signing and keys

```text
catalog payload ──Ed25519 signature──▶ runtime-catalog.signed.json
                                              │
                                              ▼
                            DSH Studio embedded public key (trust anchor)
                                              │
                                              ▼
                            select Runtime → download → verify SHA-256 → install
```

| Item | Location |
| --- | --- |
| Public key (trust anchor) | [`keys/runtime-catalog-public.txt`](keys/runtime-catalog-public.txt); the same value is embedded in the app as `RUNTIME_CATALOG_PUBLIC_KEY` (Debug and Release) |
| Private key | secret `RUNTIME_CATALOG_PRIVATE_KEY_BASE64` in the `runtime-signing` GitHub Actions environment |
| Rotation steps | [`docs/runtime-catalog-keys.md`](docs/runtime-catalog-keys.md) (Chinese) |

**Invariant**: the public key derived from the private key MUST equal
`keys/runtime-catalog-public.txt`. `sign-runtime-catalog.sh` verifies this before signing and refuses
to sign on mismatch. The post-publish job verifies the published catalog with the same key. A wrong
rotation makes every released app reject all catalogs.

**Private key constraints**: the private key MUST NOT enter Git, artifacts, CI logs, or command-line
arguments (argv is readable by other processes on the host; the environment is not). The build job does
not reference the `runtime-signing` environment and therefore cannot read the key, so an artifact
cannot contain it.

## 6. Repository configuration

Repository variables:

| Variable | Required | Description |
| --- | --- | --- |
| `RUNTIME_PNPM_VERSION` | yes | pnpm version packaged into the Runtime, for example `11.22.0` |
| `RUNTIME_DATA_FORMAT_ID` | yes | Data format ID declared by the catalog, for example `sqlite-v2` |
| `RUNTIME_DATA_FORMAT_COMPATIBLE_WITH` | no | Comma-separated compatible older format IDs |
| `RUNTIME_DATA_FORMAT_MIGRATION` | no | Migration identifier; clients never run migrations automatically |
| `RUNTIME_PLUGIN_MARKET_VERSION` | no | Pin the plugin market version; empty resolves it per Harness version |

Environment and secret:

1. Create the `runtime-signing` environment (referenced by the publish job; no required reviewers, so
   scheduled releases stay unattended).
2. Create the `RUNTIME_CATALOG_PRIVATE_KEY_BASE64` secret in it (base64 of a PKCS#8 DER key).

## 7. Local build

```bash
RUNTIME_VERSION=0.2.0-rc.1 \
ARCHITECTURE=darwin-arm64 \
PNPM_VERSION=11.22.0 \
DSH_RUNTIME_DATA_FORMAT_ID=sqlite-v2 \
  ./Scripts/build-runtime.sh
```

Sequence: download and verify Node → resolve Harness and pnpm dependencies → compile native modules
(for example `fs-ext`) → generate `manifest.json` → package → compute SHA-256 → extract to a temporary
directory and run the smoke test → write the artifact, manifest and metadata under `OUTPUT_DIR`.

| Variable | Default | Description |
| --- | --- | --- |
| `RUNTIME_VERSION` | required | Harness version, which is also the Runtime version |
| `ARCHITECTURE` | host architecture | `darwin-arm64` or `darwin-x64` |
| `PNPM_VERSION` | none | Required; the build fails without it (see below) |
| `HARNESS_VERSION` | equals `RUNTIME_VERSION` | If provided explicitly, it MUST match `RUNTIME_VERSION` |
| `DSH_RUNTIME_DATA_FORMAT_ID` | empty | Written to the manifest as `dataFormat.id` |
| `NODE_VERSION` | pinned in the script | Packaged Node version |
| `NPM_REGISTRY` | `https://registry.npmjs.org` | Dependency source, recorded in the manifest |
| `OUTPUT_DIR` | `RuntimeArtifacts/` | Output directory |
| `WORK_DIR` | temporary directory | Reuse it to keep download and install caches |
| `RUNTIME_ARTIFACT_BASE_URL` | GitHub release URL | Download URL written to the metadata |
| `PLUGIN_MARKET_VERSION` | resolved | Pin the plugin market version; `none` publishes no pin |
| `DSH_RUNTIME_ALLOW_UNPINNED_PNPM=1` | off | Let a local build resolve the latest pnpm; such builds are not publishable |
| `DSH_RUNTIME_ALLOW_MISSING_PLUGIN_MARKET=1` | off | Allow publishing without a plugin market pin |

Plugin market pin: which market version works is decided by the Harness version inside this Runtime, so
the pin travels with the Runtime instead of being compiled into the app.
`Scripts/resolve-plugin-market.js` reads each version's `peerDependencies` declaration
(`@deepseek-ai/dsh-settings`, then `@deepseek-ai/dsh`), picks the newest released version whose range
covers the current Harness (falling back to a prerelease only when no release does), and skips any
version whose range cannot be parsed. The resulting `{package, version, integrity, harnessRange}` is
written into the manifest, the metadata, and the catalog. The default is fail closed: when no version
declares support for that Harness, the build fails and points at the two remedies — pin a version with
`PLUGIN_MARKET_VERSION`, or publish no pin with `none` (clients then fall back to their compiled pin
and report the incompatibility).

## 8. Verification and tests

Three layers, increasing in cost and coverage:

```text
Scripts/run-tests.sh         offline tests (fixtures; no network, secrets, or macOS) — pull request gate
        ▼
Scripts/runtime-smoke.sh     local smoke test (run on the extracted artifact during a build)
        ▼
Scripts/verify-published-runtime.sh   post-publish re-download verification (read-only, no secret)
```

`Scripts/run-tests.sh` covers version parsing and build-input validation, catalog and metadata rules
(including `dataFormat`, `pluginMarket`, `sha256`, `size`, and cross-architecture contract equality),
catalog downgrade refusal, signing and envelope verification, the dependency audit, plugin-market
range semantics and resolution, process-tree cleanup against real processes
(`Scripts/tests/process-tree-scenarios.sh`), and negative cases against broken artifacts.

Tests come in two layers so pull requests stay fast:

| Layer | When | What |
| --- | --- | --- |
| fast (~20s, offline, no secrets) | every pull request and push to main (`verify.yml`) | all of `Scripts/run-tests.sh`: fixtures and the process-cleanup scenarios |
| heavy (needs network and the signing environment) | release runs, manual dispatch, cron (`runtime-builder.yml`) | real builds of both architectures → smoke test on the extracted artifact → sign and publish → re-download verification from the public URLs |

Smoke test checks:

1. the manifest parses and the layout matches `architecture`;
2. the packaged Node and pnpm are executable and match the manifest versions;
3. `node`, `node-pty/pty.node` and `spawn-helper` carry the Mach-O architecture the manifest claims
   (x64 is built on an Apple Silicon runner through Rosetta, where "it runs" would not catch a wrong
   architecture);
4. `node-pty` and, when present, `fs-ext` and `koffi` actually load in the packaged Node (the latter
   two ship their native binaries inside platform-specific optional dependencies, so a wrong
   architecture only shows up when they are loaded);
5. a pty can really spawn a process and return its output (exercising `spawn-helper`);
6. when the manifest carries a plugin market pin, it is installed into a scratch profile exactly as the
   app does it, and the profile's `package.json`, `node_modules` version, and `pnpm-lock.yaml` version
   and integrity are checked;
7. Harness starts with `web --host 127.0.0.1 --port 0 --no-open`, exchanges the token, and answers
   `settings/describe` — which also proves a profile carrying the pinned market boots;
8. the process is still alive after the probe and exits cleanly on SIGTERM;
9. every process observed under Harness while it was running is gone afterwards (Harness may fork its
   own host process), so no orphan outlives the shutdown.

The smoke test needs no account and no API key. Only step 6 requires the network (the market install)
and can be skipped with `DSH_RUNTIME_SMOKE_SKIP_PLUGIN_MARKET=1`. The environment is isolated: `HOME`,
`XDG_*`, and `DSH_HOME` all point into a temporary directory, so no real user data is read or written.
That step installs with scripts disabled, matching the app's policy; see section 3 of
`docs/runtime-contract.md`.

**Not covered**: the smoke test creates no session, calls no model, and does not exercise the plugin
market's own HTTP routes or UI.

## 9. How DSH Studio consumes the catalog

1. Read `runtime-catalog.signed.json` from the fixed URL and verify it with the embedded public key
   (`keyID` MUST be `runtime-catalog-v1`, `schemaVersion` MUST be 1); any failure is closed;
2. decode the payload, select the release for the host architecture, and validate `runtimeVersion`,
   the dependency pins, the data format, and the artifact description (the URL MUST equal the fixed
   shape and `sha256` MUST be 64 hex digits);
3. download the artifact, verify its SHA-256, then validate the archive layout and that `manifest.json`
   (`schemaVersion: 3`) matches the catalog entry field by field;
4. install into `Runtimes/<runtimeVersion>` without overwriting a running Runtime, then health-check it
   (`settings/describe`; 90 s startup timeout and 5 s request timeout by default);
5. on a failed health check, roll back automatically to the previous known-good Runtime; rollback is
   fully offline;
6. data compatibility: when the new Runtime declares an incompatible `dataFormat.id`, the app creates
   an isolated profile and never migrates, overwrites, or deletes existing data; a missing `dataFormat`
   blocks the update (which is why the catalog requires the field).

Full fields and semantics: [`docs/runtime-contract.md`](docs/runtime-contract.md) (Chinese).

## 10. Known limitations

- **Historical Harness versions cannot be rebuilt**: every build re-resolves the dependency graph, and
  loose upstream ranges resolve to transitive packages released after that version, producing an
  unstable mixed graph. Several versions before 0.1.5 no longer boot today, so the official release
  line starts at `0.2.0-rc.1`. Evidence: [`docs/historical-versions.md`](docs/historical-versions.md).
- **No byte-level reproducibility is claimed**: transitive dependencies are resolved from the registry
  and packaging timestamps vary per build. Identity and integrity rely on the catalog recording the
  artifact's actual SHA-256 plus the client verifying every byte — not on rebuilds producing identical
  bytes. `dependencyLockSHA256` and `provenance` make each release traceable.
- **The x64 Runtime is not validated on real Intel hardware**: it is built and tested on an Apple
  Silicon runner through Rosetta, with the architecture asserted by `lipo -archs`. Current coverage:

  | Environment | Status |
  | --- | --- |
  | Apple Silicon native execution | supported, exercised by every build |
  | x86_64 Mach-O architecture validation (`lipo`) | tested |
  | x86_64 execution under Rosetta on Apple Silicon | tested |
  | Native Intel Mac hardware | not available (no workaround added) |
- **The smoke test depends on upstream internal protocol**: a change to the `web` subcommand or the
  `settings/describe` RPC fails the build (intentionally fail closed) and requires updating
  `Scripts/runtime-smoke.sh`; this has already happened once.
- **Historical releases are never pruned**: client caches may still reference them.

## 11. Documentation index

| Document | Contents |
| --- | --- |
| [`docs/versioning.md`](docs/versioning.md) | Version rules (authoritative, frozen) |
| [`docs/runtime-contract.md`](docs/runtime-contract.md) | URL, schema, and semantic contract with the client |
| [`docs/runtime-catalog-keys.md`](docs/runtime-catalog-keys.md) | Signing key correspondence and rotation |
| [`docs/historical-versions.md`](docs/historical-versions.md) | Rebuildable range and dependency-drift evidence |

The `docs/` files are currently Chinese only.

| Tooling | Purpose |
| --- | --- |
| `.github/workflows/runtime-builder.yml` | Build, verify, sign, and publish the Runtime |
| `.github/workflows/verify.yml` | Pull request gate: the offline test suite (no secrets) |
| `Scripts/build-runtime.sh` | Build one architecture's artifact |
| `Scripts/audit-dependencies.js` | Refuse unrecorded install / native build scripts in the closure |
| `Scripts/runtime-smoke.sh` | Run the local smoke test on an extracted artifact |
| `Scripts/lib/process-tree.sh` | Record, assert and best-effort clean up a process tree (shared by the smoke and the tests) |
| `Scripts/tests/process-tree-scenarios.sh` | Scenarios that verify the cleanup against real processes |
| `Scripts/generate-runtime-catalog.sh` | Merge both architectures' metadata into the catalog |
| `Scripts/check-catalog-precedent.sh` | Refuse catalog downgrades, report same-version repacks |
| `Scripts/sign-runtime-catalog.sh` | Sign the catalog with the Ed25519 private key |
| `Scripts/verify-runtime-catalog.sh` | Verify a signature envelope and decode its payload |
| `Scripts/verify-published-runtime.sh` | Re-download and verify the published catalog and artifacts |
| `Scripts/resolve-plugin-market.js` | Resolve the plugin market version compatible with the Harness |
| `Scripts/run-tests.sh` | Offline test suite |
