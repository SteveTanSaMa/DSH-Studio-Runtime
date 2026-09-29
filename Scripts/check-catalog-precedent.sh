#!/usr/bin/env bash
set -euo pipefail

# Guards the published catalog against publishing a Runtime version older than
# the one already published, which would make fresh installations discover an
# outdated Runtime.
#
# Usage: check-catalog-precedent.sh PREVIOUS_PAYLOAD_JSON NEW_CATALOG_JSON
#
# A missing or empty PREVIOUS_PAYLOAD_JSON means this is the first catalog.
# ALLOW_CATALOG_DOWNGRADE=1 turns the version check into a warning for an
# intentional backport.
#
# Repacking the same Harness version is expected rather than forbidden: the
# Runtime identity is the Harness version, and the artifact is identified by its
# SHA-256, so a repack replaces the published artifact and is reported on stderr.

PREVIOUS_PATH="${1:-}"
NEW_PATH="${2:-}"
ALLOW_DOWNGRADE="${ALLOW_CATALOG_DOWNGRADE:-0}"

die() {
    printf 'check-catalog-precedent: %s\n' "$1" >&2
    exit 1
}

[ -n "$NEW_PATH" ] || die "usage: $0 PREVIOUS_PAYLOAD_JSON NEW_CATALOG_JSON"
[ -f "$NEW_PATH" ] || die "new catalog does not exist: $NEW_PATH"
command -v node >/dev/null 2>&1 || die "missing required command: node"

if [ -z "$PREVIOUS_PATH" ] || [ ! -f "$PREVIOUS_PATH" ]; then
    printf 'check-catalog-precedent: no previously published catalog to compare against\n'
    exit 0
fi

node - "$PREVIOUS_PATH" "$NEW_PATH" "$ALLOW_DOWNGRADE" <<'NODE'
const fs = require("fs");

const HARNESS_VERSION_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$/;

// DSH Studio orders Runtime versions by the Harness version first and, only for
// the same Harness version, by the revision the retired -verN suffix carried.
// Bare versions are the current form, and they are ordered by their prerelease
// rules (0.1.1-rc.10 < 0.1.1).
function parseRuntimeVersion(value) {
  const text = value || "";
  // The retired marker is read first, because it is the more specific form:
  // "0.1.5-rc.2-ver1" is the 0.1.5-rc.2 line with revision 1, not a Harness
  // version named that way.
  const legacy = /^(.*)-ver([1-9][0-9]*)$/.exec(text);
  if (legacy && HARNESS_VERSION_PATTERN.test(legacy[1])) {
    return { harness: legacy[1], revision: Number(legacy[2]) };
  }
  if (HARNESS_VERSION_PATTERN.test(text)) return { harness: text, revision: 0 };
  return null;
}

function parseHarnessVersion(value) {
  const match = /^([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(value || "");
  if (!match) return null;
  return {
    core: [Number(match[1]), Number(match[2]), Number(match[3])],
    prerelease: match[4] ? match[4].split(".") : []
  };
}

function comparePrereleaseIdentifier(left, right) {
  const leftNumeric = /^[0-9]+$/.test(left);
  const rightNumeric = /^[0-9]+$/.test(right);
  if (leftNumeric && rightNumeric) return Number(left) < Number(right) ? -1 : Number(left) > Number(right) ? 1 : 0;
  if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
  return left < right ? -1 : left > right ? 1 : 0;
}

function comparePrerelease(left, right) {
  // A released Harness version sorts after any prerelease of the same core.
  if (left.length === 0 && right.length === 0) return 0;
  if (left.length === 0) return 1;
  if (right.length === 0) return -1;
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    if (index >= left.length) return -1;
    if (index >= right.length) return 1;
    const result = comparePrereleaseIdentifier(left[index], right[index]);
    if (result !== 0) return result;
  }
  return 0;
}

function compareComponents(left, right) {
  // Only reached for values outside the standardised grammar.
  const split = (value) => (value || "").split(/[^0-9A-Za-z]+/).filter(Boolean);
  const leftParts = split(left);
  const rightParts = split(right);
  for (let index = 0; index < Math.max(leftParts.length, rightParts.length); index += 1) {
    if (index >= leftParts.length) return -1;
    if (index >= rightParts.length) return 1;
    const leftPart = leftParts[index];
    const rightPart = rightParts[index];
    if (/^[0-9]+$/.test(leftPart) && /^[0-9]+$/.test(rightPart)) {
      if (Number(leftPart) !== Number(rightPart)) return Number(leftPart) < Number(rightPart) ? -1 : 1;
      continue;
    }
    if (leftPart !== rightPart) return leftPart < rightPart ? -1 : 1;
  }
  return 0;
}

function compareHarnessVersions(left, right) {
  const leftVersion = parseHarnessVersion(left);
  const rightVersion = parseHarnessVersion(right);
  if (!leftVersion || !rightVersion) return compareComponents(left, right);
  for (let index = 0; index < 3; index += 1) {
    if (leftVersion.core[index] !== rightVersion.core[index]) {
      return leftVersion.core[index] < rightVersion.core[index] ? -1 : 1;
    }
  }
  return comparePrerelease(leftVersion.prerelease, rightVersion.prerelease);
}

// Mirrors DSH Studio's RuntimeVersionOrdering so the pipeline never disagrees
// with the client about which Runtime is newer.
function compareRuntimeVersions(left, right) {
  const leftVersion = parseRuntimeVersion(left);
  const rightVersion = parseRuntimeVersion(right);
  if (leftVersion && rightVersion) {
    const harnessComparison = compareHarnessVersions(leftVersion.harness, rightVersion.harness);
    if (harnessComparison !== 0) return harnessComparison;
    if (leftVersion.revision === rightVersion.revision) return 0;
    return leftVersion.revision < rightVersion.revision ? -1 : 1;
  }
  if (leftVersion && !rightVersion) return 1;
  if (!leftVersion && rightVersion) return -1;
  return compareComponents(left, right);
}

function check(previousPath, newPath, allowDowngrade) {
  const previous = JSON.parse(fs.readFileSync(previousPath, "utf8"));
  const next = JSON.parse(fs.readFileSync(newPath, "utf8"));
  if (!previous.runtimeVersion || !Array.isArray(previous.releases) ||
      !next.runtimeVersion || !Array.isArray(next.releases)) {
    throw new Error("a catalog payload is malformed");
  }

  const comparison = compareRuntimeVersions(previous.runtimeVersion, next.runtimeVersion);
  if (comparison > 0) {
    const message = `refusing to publish ${next.runtimeVersion}: the published catalog already offers ${previous.runtimeVersion}`;
    if (allowDowngrade !== "1") {
      throw new Error(`${message}; set allow_catalog_downgrade to override this for an intentional backport`);
    }
    process.stderr.write(`check-catalog-precedent: warning: ${message}\n`);
  }

  if (comparison === 0) {
    const published = new Map(previous.releases.map((release) => [
      release.architecture,
      ((release.artifact || {}).sha256 || "").toLowerCase()
    ]));
    for (const release of next.releases) {
      const publishedSHA256 = published.get(release.architecture);
      const rebuiltSHA256 = (((release.artifact || {}).sha256) || "").toLowerCase();
      if (publishedSHA256 && rebuiltSHA256 && publishedSHA256 !== rebuiltSHA256) {
        // One Harness version is one current Runtime, so a repack replaces the
        // published artifact on purpose: the new digest is what clients verify
        // and what the release assets will hold. Say so loudly, because during
        // the upload window the two disagree.
        process.stderr.write(
          `check-catalog-precedent: note: replacing the published ${release.architecture} artifact ` +
          `(${publishedSHA256} -> ${rebuiltSHA256})\n`);
      }
    }
  }

  process.stdout.write(`Runtime catalog precedent ok: ${previous.runtimeVersion} -> ${next.runtimeVersion}\n`);
}

const [previousPath, newPath, allowDowngrade] = process.argv.slice(2);
try {
  check(previousPath, newPath, allowDowngrade);
} catch (error) {
  process.stderr.write(`check-catalog-precedent: ${error.message}\n`);
  process.exit(1);
}
NODE
