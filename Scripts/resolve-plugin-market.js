#!/usr/bin/env node
"use strict";

// Resolves the first-party plugin market version that a Harness build can run.
//
// Which market version works is decided by the Harness version the Runtime
// contains, and only the Runtime publisher knows that pairing when it builds.
// The resolved pin is written into the Runtime manifest and the signed catalog,
// so DSH Studio installs exactly that package version instead of hardcoding one
// that goes stale as soon as Harness moves.
//
// Usage:
//   resolve-plugin-market.js --harness 0.2.0-rc.1 [--package dshmarket]
//                            [--registry https://registry.npmjs.org]
//                            [--version 1.66.5]
//
// Prints one JSON object: {package, version, integrity, harnessRange}.
//
// The range grammar below mirrors DSH Studio's PluginCompatibility exactly
// (Scripts/run-tests.sh pins the shared cases), so the build and the app never
// disagree about whether a market version supports the packaged Harness.

const DEFAULT_PACKAGE = "dshmarket";
const DEFAULT_REGISTRY = "https://registry.npmjs.org";
// Harness packages share one version, so a range over any of them answers the
// same question. This is the order DSH Studio reads them in.
const HARNESS_PACKAGE_NAMES = ["@deepseek-ai/dsh-settings", "@deepseek-ai/dsh"];

function parseVersion(text) {
  const trimmed = String(text === undefined || text === null ? "" : text).trim();
  if (trimmed === "") return null;
  const withoutBuild = trimmed.split("+")[0];
  const headAndPrerelease = withoutBuild.split("-");
  const head = headAndPrerelease[0];
  const prereleasePart = headAndPrerelease.length > 1 ? headAndPrerelease.slice(1).join("-") : null;
  const coreParts = head.split(".");
  if (coreParts.length < 2 || coreParts.length > 3) return null;
  const core = [];
  for (const part of coreParts) {
    if (!/^[0-9]+$/.test(part)) return null;
    core.push(Number(part));
  }
  while (core.length < 3) core.push(0);
  let prerelease = [];
  if (prereleasePart !== null) {
    const identifiers = prereleasePart.split(".");
    if (identifiers.length === 0 || identifiers.some((identifier) => identifier === "")) return null;
    prerelease = identifiers;
  }
  return { core, coreComponents: coreParts.length, prerelease };
}

function releaseOnly(version) {
  return { core: version.core.slice(), coreComponents: 3, prerelease: [] };
}

function sameCore(left, right) {
  return left.core.every((value, index) => value === right.core[index]);
}

function versionsEqual(left, right) {
  return left.coreComponents === right.coreComponents &&
    sameCore(left, right) &&
    left.prerelease.length === right.prerelease.length &&
    left.prerelease.every((value, index) => value === right.prerelease[index]);
}

function isPrerelease(version) {
  return version.prerelease.length > 0;
}

function isNumericIdentifier(identifier) {
  return /^[0-9]+$/.test(identifier);
}

function versionLessThan(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left.core[index] !== right.core[index]) return left.core[index] < right.core[index];
  }
  const leftPrerelease = isPrerelease(left);
  const rightPrerelease = isPrerelease(right);
  if (!leftPrerelease) return false; // a released version outranks any prerelease
  if (!rightPrerelease) return true;
  for (let index = 0; index < Math.max(left.prerelease.length, right.prerelease.length); index += 1) {
    if (index >= left.prerelease.length) return true; // fewer identifiers lose
    if (index >= right.prerelease.length) return false;
    const leftIdentifier = left.prerelease[index];
    const rightIdentifier = right.prerelease[index];
    if (leftIdentifier === rightIdentifier) continue;
    const leftNumeric = isNumericIdentifier(leftIdentifier);
    const rightNumeric = isNumericIdentifier(rightIdentifier);
    if (leftNumeric && rightNumeric) return Number(leftIdentifier) < Number(rightIdentifier);
    if (leftNumeric) return true; // numeric identifiers rank below alphanumeric ones
    if (rightNumeric) return false;
    return leftIdentifier < rightIdentifier;
  }
  return false;
}

function caretUpperBound(version) {
  const [major, minor, patch] = version.core;
  if (major > 0) return { core: [major + 1, 0, 0], coreComponents: 3, prerelease: [] };
  if (minor > 0) return { core: [0, minor + 1, 0], coreComponents: 3, prerelease: [] };
  return { core: [0, 0, patch + 1], coreComponents: 3, prerelease: [] };
}

function tildeUpperBound(version) {
  return { core: [version.core[0], version.core[1] + 1, 0], coreComponents: 3, prerelease: [] };
}

function parseComparator(text) {
  const operators = [
    [">=", "greaterThanOrEqual"],
    ["<=", "lessThanOrEqual"],
    [">", "greaterThan"],
    ["<", "lessThan"],
    ["^", "caret"],
    ["~", "tilde"],
    ["=", "equal"]
  ];
  let operator = "equal";
  let remainder = text;
  for (const [prefix, candidate] of operators) {
    if (text.startsWith(prefix)) {
      operator = candidate;
      remainder = text.slice(prefix.length);
      break;
    }
  }
  const version = parseVersion(remainder);
  if (!version) return null;
  // `~1` has no minor component to hold the upper bound.
  if (operator === "tilde" && version.coreComponents < 2) return null;
  return { operator, version };
}

function comparatorAllows(comparator, subject) {
  const { operator, version } = comparator;
  const exactPrerelease = isPrerelease(subject) && isPrerelease(version) && sameCore(version, subject);
  const onLine = isPrerelease(subject) && !exactPrerelease;
  const candidate = onLine ? releaseOnly(subject) : subject;
  const bound = onLine ? releaseOnly(version) : version;
  switch (operator) {
    case "equal":
      return versionsEqual(candidate, bound);
    case "greaterThan":
      return versionLessThan(bound, candidate);
    case "greaterThanOrEqual":
      return !versionLessThan(candidate, bound);
    case "lessThan":
      return versionLessThan(candidate, bound);
    case "lessThanOrEqual":
      return !versionLessThan(bound, candidate);
    case "caret":
      return !versionLessThan(candidate, bound) && versionLessThan(candidate, caretUpperBound(bound));
    case "tilde":
      return !versionLessThan(candidate, bound) && versionLessThan(candidate, tildeUpperBound(bound));
    default:
      return false;
  }
}

// Returns true, false, or null when the range cannot be read.
function satisfies(version, range) {
  const subject = parseVersion(version);
  if (!subject) return null;
  const alternatives = String(range === undefined || range === null ? "" : range).split("||");
  if (alternatives.length === 0) return null;

  // Every alternative is read before any is trusted: a range with one unreadable
  // part is undecidable as a whole, not satisfied by whichever part came first.
  const sets = [];
  for (const alternative of alternatives) {
    const trimmed = alternative.trim();
    if (trimmed === "") return null;
    const parts = trimmed.split(/\s+/);
    if (parts.length === 0) return null;
    const comparators = [];
    for (const part of parts) {
      const comparator = parseComparator(part);
      if (!comparator) return null;
      comparators.push(comparator);
    }
    sets.push(comparators);
  }
  return sets.some((comparators) => comparators.every((comparator) => comparatorAllows(comparator, subject)));
}

function declaredHarnessRange(manifest) {
  const peers = (manifest && manifest.peerDependencies) || {};
  for (const name of HARNESS_PACKAGE_NAMES) {
    const range = peers[name];
    if (typeof range === "string" && range.trim() !== "") return range;
  }
  return null;
}

// Chooses the newest version whose declared Harness range accepts `harnessVersion`.
//
// Candidates whose range cannot be read are skipped rather than trusted: the pin
// is what users install, so it has to be verifiable at build time. Released
// versions win over prereleases of the same package.
function selectPin(candidates, harnessVersion, options = {}) {
  const packageName = options.package || DEFAULT_PACKAGE;
  const compatible = [];
  for (const candidate of candidates) {
    if (!candidate || !candidate.version || !candidate.integrity || !candidate.harnessRange) continue;
    if (satisfies(harnessVersion, candidate.harnessRange) !== true) continue;
    const parsed = parseVersion(candidate.version);
    if (!parsed) continue;
    compatible.push({ ...candidate, parsed });
  }
  if (compatible.length === 0) {
    throw new Error(
      `no ${packageName} version declares support for Harness ${harnessVersion}; ` +
      "pass --version to pin one explicitly");
  }
  const released = compatible.filter((candidate) => !isPrerelease(candidate.parsed));
  const pool = released.length > 0 ? released : compatible;
  pool.sort((left, right) => (versionLessThan(left.parsed, right.parsed) ? 1 : -1));
  const chosen = pool[0];
  return {
    package: packageName,
    version: chosen.version,
    integrity: chosen.integrity,
    harnessRange: chosen.harnessRange
  };
}

function candidatesFromPackument(packument) {
  const versions = (packument && packument.versions) || {};
  return Object.keys(versions).map((version) => ({
    version,
    integrity: (versions[version].dist || {}).integrity || "",
    harnessRange: declaredHarnessRange(versions[version])
  }));
}

async function fetchPackument(registry, packageName) {
  const base = String(registry || DEFAULT_REGISTRY).replace(/\/+$/, "");
  const url = `${base}/${packageName.replace("/", "%2F")}`;
  const response = await fetch(url, {
    headers: { accept: "application/vnd.npm.install-v1+json" }
  });
  if (!response.ok) {
    throw new Error(`${url} answered HTTP ${response.status}`);
  }
  return response.json();
}

function parseArguments(argv) {
  const options = { package: DEFAULT_PACKAGE, registry: DEFAULT_REGISTRY, version: "", harness: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const value = argv[index + 1];
    switch (argument) {
      case "--package":
        options.package = value || "";
        index += 1;
        break;
      case "--registry":
        options.registry = value || "";
        index += 1;
        break;
      case "--version":
        options.version = value || "";
        index += 1;
        break;
      case "--harness":
        options.harness = value || "";
        index += 1;
        break;
      default:
        throw new Error(`unknown argument: ${argument}`);
    }
  }
  if (!options.harness) throw new Error("--harness is required");
  if (parseVersion(options.harness) === null) throw new Error(`--harness is not a version: ${options.harness}`);
  return options;
}

async function resolve(options) {
  const packument = await fetchPackument(options.registry, options.package);
  const versions = (packument && packument.versions) || {};
  if (options.version) {
    const manifest = versions[options.version];
    if (!manifest) throw new Error(`${options.package}@${options.version} does not exist`);
    const integrity = (manifest.dist || {}).integrity || "";
    if (!integrity) throw new Error(`${options.package}@${options.version} publishes no integrity`);
    const harnessRange = declaredHarnessRange(manifest);
    if (!harnessRange) {
      process.stderr.write(
        `resolve-plugin-market: warning: ${options.package}@${options.version} declares no Harness range; ` +
        "DSH Studio will fall back to the range the installed package declares\n");
    } else if (satisfies(options.harness, harnessRange) !== true) {
      process.stderr.write(
        `resolve-plugin-market: warning: ${options.package}@${options.version} declares ${harnessRange}, ` +
        `which does not cover Harness ${options.harness}\n`);
    }
    return { package: options.package, version: options.version, integrity, harnessRange };
  }
  return selectPin(candidatesFromPackument(packument), options.harness, { package: options.package });
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const pin = await resolve(options);
  process.stdout.write(JSON.stringify(pin, null, 2) + "\n");
  process.stderr.write(
    `resolve-plugin-market: Harness ${options.harness} -> ${pin.package}@${pin.version}\n`);
}

module.exports = {
  candidatesFromPackument,
  declaredHarnessRange,
  parseVersion,
  satisfies,
  selectPin,
  versionLessThan
};

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`resolve-plugin-market: ${error.message}\n`);
    process.exit(1);
  });
}
