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
  const section = (chinese) => {
    const lines = [
      chinese ? "DSH Studio 运行时安装包。" : "DSH Studio Runtime artifact.",
      "",
      chinese ? "| 项目 | 内容 |" : "| Item | Value |",
      "| --- | --- |",
      `| Harness | ${code(first.harnessVersion)} |`,
      `| ${chinese ? "平台" : "Platform"} | ${code(first.platform || "macos")} |`,
      `| Node | ${code(first.nodeVersion)} |`,
      `| pnpm | ${code(first.pnpmVersion)} |`,
      `| ${chinese ? "数据格式" : "Data format"} | ${code(first.dataFormat.id)} |`
    ];
    if (provenance.commit || provenance.runId) {
      lines.push(`| ${chinese ? "构建来源" : "Built from"} | ${code(provenance.commit || "unknown")} (${code(provenance.ref || "unknown")}), ${chinese ? "运行编号" : "run"} ${code(provenance.runId || "unknown")} |`);
    }
    lines.push("", chinese
      ? `Runtime 版本与 Harness 版本 ${code(runtimeVersion)} 相同。重新打包会替换同一版本的安装包，客户端以签名目录中的 SHA-256 校验下载内容。`
      : `The Runtime version is the Harness version ${code(runtimeVersion)}. Repacking replaces the artifacts in place; clients verify the downloaded bytes against the signed catalog's SHA-256.`,
      "", chinese ? "| 架构 | 安装包 | SHA-256 | 大小 |" : "| Architecture | Artifact | SHA-256 | Size |",
      "| --- | --- | --- | --- |");
    for (const item of metadata) {
      lines.push(`| ${code(item.architecture)} | ${code(item.artifact)} | ${code(item.sha256)} | ${item.size} ${chinese ? "字节" : "bytes"} |`);
    }
    lines.push("", chinese ? "各架构的依赖锁文件摘要：" : "Dependency lock digests by architecture:", "");
    for (const item of metadata) {
      lines.push(`- ${code(item.architecture)}: ${code(item.dependencyLockSHA256 || "unknown")}`);
    }
    lines.push("", chinese ? "本版本的签名运行时目录：" : "Signed catalog for this Runtime release:",
      `https://github.com/${repository}/releases/download/runtime-${runtimeVersion}/runtime-catalog.signed.json`,
      "", chinese ? "DSH Studio 自动发现最新版使用的签名目录：" : "Signed catalog used by DSH Studio to discover the latest Runtime:",
      `https://github.com/${repository}/releases/download/runtime-catalog/runtime-catalog.signed.json`);
    return lines.join("\n");
  };
  return section(true) + "\n\n---\n\n" + section(false) + "\n";
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
