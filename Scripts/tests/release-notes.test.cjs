"use strict";

const { test, afterEach } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { generateNotes } = require("../generate-runtime-release-notes.js");
const directories = [];
afterEach(() => {
  for (const directory of directories.splice(0)) fs.rmSync(directory, { recursive: true });
});

function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "runtime-notes-"));
  directories.push(directory);
  for (const architecture of ["darwin-arm64", "darwin-x64"]) {
    fs.writeFileSync(path.join(directory, `artifact-0.2.1-rc.2-${architecture}.json`), JSON.stringify({
      runtimeVersion: "0.2.1-rc.2", harnessVersion: "0.2.1-rc.2", architecture,
      nodeVersion: "26.12.1", pnpmVersion: "11.22.0", platform: "macos",
      dataFormat: { id: "sqlite-v2" }, artifact: `${architecture}.tar.gz`,
      sha256: architecture === "darwin-arm64" ? "a".repeat(64) : "b".repeat(64),
      size: 1234, dependencyLockSHA256: `${architecture}-lock`,
      provenance: { commit: "current-commit", ref: "refs/heads/main", runId: "42" }
    }));
  }
  return directory;
}

test("shared bilingual tables retain current downloads, checksums and build links without duplicated sections", () => {
  const notes = generateNotes(fixture(), "0.2.1-rc.2", "owner/runtime");
  assert.match(notes, /组件 \/ Component/);
  assert.match(notes, /架构 \/ Architecture/);
  for (const expected of ["26.12.1", "a".repeat(64), "b".repeat(64)]) {
    assert.equal(notes.split(expected).length - 1, 1, expected);
  }
  for (const expected of [
    "owner/runtime/releases/download/runtime-0.2.1-rc.2/darwin-arm64.tar.gz",
    "owner/runtime/releases/download/runtime-0.2.1-rc.2/darwin-x64.tar.gz",
    "owner/runtime/releases/download/runtime-0.2.1-rc.2/runtime-catalog.signed.json",
    "owner/runtime/releases/download/runtime-catalog/runtime-catalog.signed.json",
    "owner/runtime/commit/current-commit", "owner/runtime/actions/runs/42"
  ]) assert.ok(notes.includes(expected), expected);
  assert.equal(notes.includes("\n\n---\n\n"), false);
  assert.equal(notes.split("1234 bytes").length - 1, 2);
  assert.doesNotMatch(notes, /\b(?:KiB|MiB|GiB)\b/);
});

test("missing or duplicate architectures cannot produce release notes", () => {
  const directory = fixture();
  const x64 = path.join(directory, "artifact-0.2.1-rc.2-darwin-x64.json");
  fs.unlinkSync(x64);
  assert.throws(() => generateNotes(directory, "0.2.1-rc.2", "owner/runtime"), /each macOS architecture/);
  fs.copyFileSync(path.join(directory, "artifact-0.2.1-rc.2-darwin-arm64.json"), x64);
  assert.throws(() => generateNotes(directory, "0.2.1-rc.2", "owner/runtime"), /each macOS architecture/);
});

test("stale metadata cannot be displayed as another Runtime version", () => {
  assert.throws(() => generateNotes(fixture(), "0.2.0-rc.1", "owner/runtime"), /requested Runtime/);
});
