#!/usr/bin/env node
"use strict";

// Fails the build when the resolved dependency graph contains a package whose
// install or native build script the Runtime deliberately does not run.
//
// The Runtime is installed with --ignore-scripts (see build-runtime.sh): install
// scripts are a supply-chain surface, and the build handles the few packages that
// genuinely need one explicitly. The cost of that policy is silence: a package
// added by a future Harness release would ship unbuilt, and the failure would only
// appear when a user triggers the feature that needs it. This audit turns that
// silence into a build failure.
//
// Usage: audit-dependencies.js PACKAGE_LOCK_JSON
//
// Every entry below is a deliberate decision and states either which explicit
// build step replaces the script or which smoke assertion covers the package.

const ALLOWED_INSTALL_SCRIPTS = {
  // Its only action is chmod +x on node-pty's prebuilt spawn-helper.
  "@deepseek-ai/dsh-subprocess-local":
    "replaced by the explicit chmod in build-runtime.sh, asserted by runtime-smoke.sh",
  // Pure JavaScript SDK; no script output is needed at runtime.
  "@google/genai": "pure JavaScript, nothing built at install time",
  // The native binding ships in the platform-specific optional dependency
  // (@koromix/koffi-<platform>); the script only builds from source when no
  // prebuilt matches the host.
  koffi: "native binding ships in @koromix/koffi-<platform>",
  // pty.node and spawn-helper ship in the package tarball; runtime-smoke.sh loads
  // the module and spawns a real pty through it.
  "node-pty": "prebuilds ship in the tarball, exercised by runtime-smoke.sh",
  // Pure JavaScript; its postinstall only generates optional legacy code paths.
  protobufjs: "pure JavaScript, nothing built at install time"
};

const fs = require("fs");

function packageNameOf(lockPath) {
  const marker = "node_modules/";
  const index = lockPath.lastIndexOf(marker);
  return index >= 0 ? lockPath.slice(index + marker.length) : lockPath;
}

function audit(lockPath) {
  const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
  const packages = lock.packages || {};
  const unexpected = [];
  const matched = new Set();

  for (const [key, meta] of Object.entries(packages)) {
    if (!key) continue;
    if (!meta.hasInstallScript && !meta.gypfile) continue;
    const name = packageNameOf(key);
    if (Object.prototype.hasOwnProperty.call(ALLOWED_INSTALL_SCRIPTS, name)) {
      matched.add(name);
      continue;
    }
    unexpected.push(`${name}@${meta.version}${meta.gypfile ? " (native build)" : " (install script)"}`);
  }

  for (const name of Object.keys(ALLOWED_INSTALL_SCRIPTS)) {
    if (!matched.has(name)) {
      process.stderr.write(
        `audit-dependencies: note: ${name} is allowlisted but no longer in the dependency graph; ` +
        "remove it from ALLOWED_INSTALL_SCRIPTS\n");
    }
  }

  if (unexpected.length > 0) {
    throw new Error(
      `${unexpected.length} package(s) in the resolved graph declare an install script the Runtime does ` +
      `not run: ${unexpected.join(", ")}. Decide explicitly, then re-run: handle the package in ` +
      "build-runtime.sh (build or fetch the binding there) and verify it in runtime-smoke.sh, or add it " +
      "to ALLOWED_INSTALL_SCRIPTS in Scripts/audit-dependencies.js with the reason it needs no build step");
  }

  process.stdout.write(
    `audit-dependencies: ${matched.size} allowlisted install script(s), no unexpected ones\n`);
}

try {
  const lockPath = process.argv[2];
  if (!lockPath) throw new Error("usage: audit-dependencies.js PACKAGE_LOCK_JSON");
  audit(lockPath);
} catch (error) {
  process.stderr.write(`audit-dependencies: ${error.message}\n`);
  process.exit(1);
}
