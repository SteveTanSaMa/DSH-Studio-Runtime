#!/usr/bin/env bash
set -euo pipefail

# Combines architecture-specific Builder metadata into the catalog published by
# the Runtime repository.
#
# The catalog describes exactly one Runtime version with immutable artifact URLs
# and checksums, so publishing it replaces the previous catalog: it must never
# move backwards, and it must never advertise bytes that were not verified in
# this run. check-catalog-precedent.sh guards the first property, this script
# guards the second.

RUNTIME_VERSION="${RUNTIME_VERSION:-${1:-}}"
OUTPUT_PATH="${OUTPUT_PATH:-${2:-}}"

die() {
    printf 'generate-runtime-catalog: %s\n' "$1" >&2
    exit 1
}

command -v node >/dev/null 2>&1 || die "missing required command: node"
[ -n "$RUNTIME_VERSION" ] || die "usage: $0 RUNTIME_VERSION OUTPUT_PATH ARTIFACT_METADATA... [--allow-missing-artifacts]"
[ -n "$OUTPUT_PATH" ] || die "output path is required"
[ "$#" -ge 3 ] || die "at least two architecture metadata files are required"
shift 2

ALLOW_MISSING_ARTIFACTS=0
METADATA_PATHS=()
for argument in "$@"; do
    case "$argument" in
        --allow-missing-artifacts) ALLOW_MISSING_ARTIFACTS=1 ;;
        -*) die "unknown option: $argument" ;;
        *) METADATA_PATHS+=("$argument") ;;
    esac
done

[ "${#METADATA_PATHS[@]}" -ge 2 ] || die "at least two architecture metadata files are required"
for metadata in "${METADATA_PATHS[@]}"; do
    [ -f "$metadata" ] || die "metadata file does not exist: $metadata"
done

mkdir -p "$(dirname "$OUTPUT_PATH")"
node - "$RUNTIME_VERSION" "$OUTPUT_PATH" "$ALLOW_MISSING_ARTIFACTS" "${METADATA_PATHS[@]}" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const [runtimeVersion, outputPath, allowMissingArtifacts, ...metadataPaths] =
  process.argv.slice(2);

const sha256File = (filePath) => new Promise((resolve, reject) => {
  const hash = crypto.createHash("sha256");
  fs.createReadStream(filePath)
    .on("error", reject)
    .on("data", (chunk) => hash.update(chunk))
    .on("end", () => resolve(hash.digest("hex")));
});

(async () => {
  // Keep in sync with build-runtime.sh and runtime-builder.yml: the Runtime
  // version is the officially published Harness version, with no build counter.
  if (!/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$/.test(runtimeVersion)) {
    throw new Error(`runtime version must be the Harness version, for example 0.2.0-rc.1: ${runtimeVersion}`);
  }
  // One Harness version is one current Runtime: a build counter must not come
  // back through hand-written metadata either.
  if (/-ver[0-9]|-r[0-9]|-rebuild-[0-9]|-revision-[0-9]/.test(runtimeVersion)) {
    throw new Error(`runtime version must not carry a build counter: ${runtimeVersion}`);
  }

  const releases = [];
  for (const metadataPath of metadataPaths) {
    const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
    if (metadata.runtimeVersion !== runtimeVersion) {
      throw new Error(`runtime version mismatch in ${metadataPath}`);
    }
    if (!metadata.url || !metadata.sha256 || !metadata.architecture ||
        !metadata.nodeVersion || !metadata.harnessVersion || !metadata.pnpmVersion ||
        !metadata.nodeArchiveSHA256 || !metadata.harnessPackageIntegrity ||
        !metadata.pnpmPackageIntegrity) {
      throw new Error(`incomplete artifact metadata in ${metadataPath}`);
    }
    // The catalog names the upstream identity, and the Runtime version must be
    // exactly that identity: refuse metadata where the two disagree, so a client
    // can never read a Harness version the artifact does not actually contain.
    if (metadata.harnessVersion !== runtimeVersion) {
      throw new Error(
        `Harness version ${metadata.harnessVersion} does not match the Runtime version ${runtimeVersion} in ${metadataPath}`);
    }
    if (!Number.isInteger(metadata.size) || metadata.size <= 0) {
      throw new Error(`artifact metadata is missing the artifact size in ${metadataPath}`);
    }
    // DSH Studio reads a Runtime without a declared data format as unknown and
    // then refuses to update an installation that already holds user data, so a
    // published Runtime must always declare one.
    if (!metadata.dataFormat ||
        typeof metadata.dataFormat.id !== "string" ||
        !metadata.dataFormat.id.trim()) {
      throw new Error(`artifact metadata must declare a data format in ${metadataPath}`);
    }
    if (!Array.isArray(metadata.dataFormat.compatibleWith) ||
        metadata.dataFormat.compatibleWith.some((value) => typeof value !== "string" || !value.trim())) {
      throw new Error(`invalid data format declaration in ${metadataPath}`);
    }
    // Which plugin market version runs on this Harness is decided by the build, so
    // the metadata has to carry that decision: the key must be present even when
    // the answer is "publish no pin", which is only reachable through an explicit
    // opt-out in build-runtime.sh.
    if (!Object.prototype.hasOwnProperty.call(metadata, "pluginMarket")) {
      throw new Error(`artifact metadata does not decide on a plugin market pin in ${metadataPath}`);
    }
    if (metadata.pluginMarket !== null) {
      const pin = metadata.pluginMarket;
      const invalid = !pin || typeof pin.package !== "string" || !pin.package.trim() ||
        typeof pin.version !== "string" || !pin.version.trim() ||
        typeof pin.integrity !== "string" || !pin.integrity.trim();
      const invalidRange = pin && pin.harnessRange != null &&
        (typeof pin.harnessRange !== "string" || !pin.harnessRange.trim());
      if (invalid || invalidRange) {
        throw new Error(`invalid plugin market pin in ${metadataPath}`);
      }
    }
    const expectedArtifact = `dsh-runtime-${runtimeVersion}-${metadata.architecture}.tar.gz`;
    const expectedManifest = `manifest-${runtimeVersion}-${metadata.architecture}.json`;
    if (metadata.artifact !== expectedArtifact || metadata.manifest !== expectedManifest) {
      throw new Error(`artifact naming does not match Runtime version in ${metadataPath}`);
    }
    if (!/^[0-9a-fA-F]{64}$/.test(metadata.sha256) ||
        !/^[0-9a-fA-F]{64}$/.test(metadata.nodeArchiveSHA256)) {
      throw new Error(`invalid checksum in ${metadataPath}`);
    }

    // The catalog advertises these exact bytes, so metadata alone is not enough:
    // the archive is re-hashed and re-measured here, in the job that publishes
    // the catalog, instead of trusting a checksum that travelled separately.
    const artifactPath = path.join(path.dirname(metadataPath), metadata.artifact);
    if (fs.existsSync(artifactPath)) {
      const actualSHA256 = await sha256File(artifactPath);
      if (actualSHA256 !== metadata.sha256.toLowerCase()) {
        throw new Error(`artifact checksum does not match its metadata: ${metadata.artifact}`);
      }
      if (fs.statSync(artifactPath).size !== metadata.size) {
        throw new Error(`artifact size does not match its metadata: ${metadata.artifact}`);
      }
    } else if (allowMissingArtifacts === "1") {
      process.stderr.write(
        `generate-runtime-catalog: warning: ${metadata.artifact} is missing, its checksum was not verified\n`);
    } else {
      throw new Error(`artifact is missing next to its metadata: ${artifactPath}`);
    }

    releases.push({
      runtimeVersion: metadata.runtimeVersion,
      platform: metadata.platform || "macos",
      architecture: metadata.architecture,
      nodeVersion: metadata.nodeVersion,
      harnessVersion: metadata.harnessVersion,
      pnpmVersion: metadata.pnpmVersion,
      nodeArchiveSHA256: metadata.nodeArchiveSHA256,
      harnessPackageIntegrity: metadata.harnessPackageIntegrity,
      pnpmPackageIntegrity: metadata.pnpmPackageIntegrity,
      dependencyLockSHA256: metadata.dependencyLockSHA256 || null,
      pluginMarket: metadata.pluginMarket === null ? null : {
        package: metadata.pluginMarket.package,
        version: metadata.pluginMarket.version,
        integrity: metadata.pluginMarket.integrity,
        harnessRange: metadata.pluginMarket.harnessRange || null
      },
      dataFormat: metadata.dataFormat,
      artifact: {
        runtimeVersion: metadata.runtimeVersion,
        architecture: metadata.architecture,
        url: metadata.url,
        sha256: metadata.sha256.toLowerCase(),
        size: metadata.size
      }
    });
  }

  // Both architectures build independently, so name the field that disagrees:
  // "the plugin market published between the two builds" is the likely cause.
  const contractFields = (release) => ({
    platform: release.platform,
    nodeVersion: release.nodeVersion,
    harnessVersion: release.harnessVersion,
    pnpmVersion: release.pnpmVersion,
    harnessPackageIntegrity: release.harnessPackageIntegrity,
    pnpmPackageIntegrity: release.pnpmPackageIntegrity,
    pluginMarket: release.pluginMarket,
    dataFormat: release.dataFormat
  });
  const reference = contractFields(releases[0]);
  for (const release of releases) {
    const fields = contractFields(release);
    for (const name of Object.keys(reference)) {
      if (JSON.stringify(fields[name]) !== JSON.stringify(reference[name])) {
        throw new Error(
          "architecture metadata does not share one Runtime contract: " +
          `${name} differs between ${releases[0].architecture} and ${release.architecture}`);
      }
    }
  }

  const architectures = new Set(releases.map((release) => release.architecture));
  if (architectures.size !== releases.length || !architectures.has("darwin-arm64") || !architectures.has("darwin-x64")) {
    throw new Error("catalog must contain exactly one arm64 and one x86_64 Runtime");
  }

  fs.writeFileSync(outputPath, JSON.stringify({
    schemaVersion: 1,
    runtimeVersion,
    releases
  }, null, 2) + "\n");
})().catch((error) => {
  process.stderr.write(`generate-runtime-catalog: ${error.message}\n`);
  process.exit(1);
});
NODE

printf 'Runtime catalog ready: %s\n' "$OUTPUT_PATH"
