# Runtime versioning

本文件是 Runtime 版本规则的权威说明（已冻结）。脚本、workflow 与文档都以它为准。

## 规则

**Runtime 的公开正式版本号 = 官方 Harness 版本。**

```text
Harness 0.2.0-rc.1   →   Runtime 0.2.0-rc.1
```

1. **Runtime version 使用 Harness version**：`runtimeVersion` 就是上游 `@deepseek-ai/dsh` 的版本号。
   本仓库不重新解释它、不补 patch、不加构建元数据。
2. **Release tag**：`runtime-<runtimeVersion>`，例如 `runtime-0.2.0-rc.1`。
3. **Release 标题**：`Runtime <runtimeVersion>`。
4. **Artifact 文件名**：`dsh-runtime-<runtimeVersion>-<architecture>.tar.gz`，例如
   `dsh-runtime-0.2.0-rc.1-darwin-arm64.tar.gz`；随附 metadata 为
   `manifest-<runtimeVersion>-<architecture>.json` 与 `artifact-<runtimeVersion>-<architecture>.json`。
5. **重新打包不产生新的 Runtime version**：同一个 Harness 版本重新构建后仍是同一个版本号、同一个
   tag、同一个文件名，替换的是 release 附件与 catalog 里的 `sha256`。失败的旧构建属于构建历史，
   不进入正式 catalog，也不作为正式 Runtime artifact 保留。
6. **SHA-256 负责 artifact integrity**：catalog 记录实际产物的 `sha256` 与 `size`，客户端下载后
   逐字节校验，失败即关闭。版本号不承担校验职责。
7. **CI 信息不是版本身份**：workflow run ID、run number、commit SHA、构建时间只用于追溯，写在
   manifest 的 `provenance` 与 Release 正文里，绝不进入版本号、tag 或文件名。

## 明确不再使用的写法

```text
0.2.0-rc.1-ver1          ✗  已退役的构建计数
0.2.0-rc.1-r1            ✗
0.2.0-rc.1-rebuild-1     ✗
Runtime 0.2.0-rc.1 (revision 1)   ✗
Runtime 0.2.0-rc.1 (rebuild 1)    ✗
```

## 排序

版本按 semver 解析比较，不做字符串比较：`0.2.0-rc.9 < 0.2.0-rc.10 < 0.2.0 < 0.2.1`。
客户端 `RuntimeVersionOrdering` 与发布侧 `Scripts/check-catalog-precedent.sh` 必须保持一致。

## 强制点

| 规则 | 在哪里强制 |
| --- | --- |
| 版本号形态（拒绝构建计数） | `Scripts/build-runtime.sh`、`.github/workflows/runtime-builder.yml`、`Scripts/generate-runtime-catalog.sh` |
| tag、标题 | `.github/workflows/runtime-builder.yml` |
| 文件名 | `Scripts/build-runtime.sh` |
| `sha256` / `size` 复核 | `Scripts/build-runtime.sh` 计算、`Scripts/generate-runtime-catalog.sh` 复核并写入 catalog |
| 不允许降级发布 | `Scripts/check-catalog-precedent.sh` |
| 离线测试 | `Scripts/run-tests.sh`（无需网络、密钥或 macOS） |

## 与客户端的关系

DSH Studio 用 catalog 里的 `runtimeVersion` 逐字符拼出可下载地址，并用同一套 semver 规则判断是否
需要更新。因此**版本号、tag、文件名三者的格式是发布端与客户端之间的契约**，改动前先读
[`runtime-contract.md`](runtime-contract.md)。
