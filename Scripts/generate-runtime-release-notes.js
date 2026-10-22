#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");

function generateNotes(directory, runtimeVersion, repository) {
  const metadata = fs.readdirSync(directory)
    .filter((name) => /^artifact-.*\.json$/.test(name))
    .map((name) => JSON.parse(fs.readFileSync(path.join(directory, name), "utf8")))
    .sort((left, right) => left.architecture.localeCompare(right.architecture));
  if (metadata.length !== 2 ||
      new Set(metadata.map((item) => item.architecture)).size !== 2 ||
      !metadata.some((item) => item.architecture === "darwin-arm64") ||
      !metadata.some((item) => item.architecture === "darwin-x64")) {
    throw new Error("expected one artifact metadata file for each macOS architecture");
  }
  for (const item of metadata) {
    if (item.runtimeVersion !== runtimeVersion || item.harnessVersion !== runtimeVersion ||
        !item.dataFormat?.id || !item.nodeVersion || !item.pnpmVersion ||
        !item.artifact || !item.sha256 || !Number.isInteger(item.size) || item.size <= 0) {
      throw new Error("artifact metadata does not describe the requested Runtime");
    }
  }
  const first = metadata[0];
  const provenance = first.provenance || {};
  const code = (value) => "`" + String(value).replace(/[\r\n]/g, " ").replace(/\|/g, "\\|").replace(/`/g, "\\`") + "`";
  const releaseURL = `https://github.com/${repository}/releases/download/runtime-${runtimeVersion}`;
  const lines = [
    "供 DSH Studio 使用的 macOS 运行环境。 / macOS runtime for DSH Studio.",
    "",
    "| 组件 / Component | 版本 / Version |",
    "| --- | --- |",
    `| Harness | ${code(first.harnessVersion)} |`,
    `| Node.js | ${code(first.nodeVersion)} |`,
    `| pnpm | ${code(first.pnpmVersion)} |`,
    `| 数据格式 / Data format | ${code(first.dataFormat.id)} |`,
    "",
    "| 架构 / Architecture | 下载 / Download | SHA-256 | 大小 / Size |",
    "| --- | --- | --- | --- |"
  ];
  for (const item of metadata) {
    lines.push(`| ${code(item.architecture)} | [tar.gz](${releaseURL}/${encodeURIComponent(item.artifact)}) | ${code(item.sha256)} | ${(item.size / 1024 / 1024).toFixed(1)} MiB |`);
  }
  lines.push("",
    `[本版签名索引 / Release catalog](${releaseURL}/runtime-catalog.signed.json) · ` +
    `[最新版索引 / Latest catalog](https://github.com/${repository}/releases/download/runtime-catalog/runtime-catalog.signed.json)`);
  const source = [];
  if (provenance.commit) source.push(`[${String(provenance.commit).slice(0, 7)}](https://github.com/${repository}/commit/${encodeURIComponent(provenance.commit)})`);
  if (provenance.runId) source.push(`[Actions #${provenance.runId}](https://github.com/${repository}/actions/runs/${encodeURIComponent(provenance.runId)})`);
  if (source.length) lines.push("", `构建来源 / Build: ${source.join(" · ")}`);
  return lines.join("\n") + "\n";
}

module.exports = { generateNotes };
if (require.main === module) {
  try {
    const [output, directory, version] = process.argv.slice(2);
    if (!output || !directory || !version) throw new Error("usage: generate-runtime-release-notes.js OUTPUT METADATA_DIRECTORY RUNTIME_VERSION");
    fs.writeFileSync(output, generateNotes(directory, version,
      process.env.GITHUB_REPOSITORY || "SteveTanSaMa/DSH-Studio-Runtime"));
  } catch (error) {
    process.stderr.write(`generate-runtime-release-notes: ${error.message}\n`);
    process.exitCode = 1;
  }
}
