# DSH Studio Runtime

这个仓库负责构建、验证和发布 DSH Studio 使用的 Runtime。App 仓库
[DSH Studio](https://github.com/SteveTanSaMa/DSH-Studio) 只保留 Runtime
发现、下载、签名校验、安装和更新逻辑。

## 内容

- `.github/workflows/runtime-builder.yml`：按架构构建并发布 Runtime。
- `Scripts/build-runtime.sh`：下载固定 Node.js、解析 Harness/pnpm 依赖、生成 Runtime artifact。
- `Scripts/runtime-smoke.sh`：启动 Harness 并执行 `settings/describe` smoke test。
- `Scripts/generate-runtime-catalog.sh`：合并两个架构的 artifact metadata。
- `Scripts/sign-runtime-catalog.sh`：使用 Ed25519 私钥签名 catalog。

构建产生的压缩包、manifest、artifact metadata 和 catalog 只作为 GitHub Actions artifact 或
GitHub Release 资产发布，不提交到 Git 源码仓库。Runtime 不再额外生成
`*.tar.gz.sha256` 文件；GitHub Release 会显示每个附件的 SHA-256，用户可以直接复制。
但 artifact metadata 和签名 catalog 中仍保留 SHA-256，用于 DSH Studio 下载时自动校验。

## 命名规范

Runtime 版本使用：

```text
<HarnessVersion>-verN
```

例如：

```text
0.1.1-rc.2-ver1
```

对应 artifact：

```text
dsh-runtime-0.1.1-rc.2-ver1-darwin-arm64.tar.gz
dsh-runtime-0.1.1-rc.2-ver1-darwin-x64.tar.gz
```

## 发布前配置

在仓库设置以下变量或 workflow dispatch 输入：

- `RUNTIME_DATA_FORMAT_ID`：Runtime 使用的数据格式，例如 `sqlite-v2`。
- `RUNTIME_DATA_FORMAT_COMPATIBLE_WITH`：明确确认兼容的旧格式 ID，逗号分隔。
- `RUNTIME_DATA_FORMAT_MIGRATION`：已存在官方迁移机制时填写迁移标识。
- `RUNTIME_PNPM_VERSION`：可选的固定 pnpm 版本。

仓库 Secrets 必须包含：

```text
RUNTIME_CATALOG_PRIVATE_KEY_BASE64
```

私钥只用于签名，不应写入仓库。App 内置对应的 Ed25519 公钥，并只信任
下面两个固定地址：

```text
https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-catalog/runtime-catalog.signed.json
https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-<version>/dsh-runtime-<version>-<architecture>.tar.gz
```

## 触发构建

推荐通过 GitHub Actions 的 `workflow_dispatch` 输入完整的 Runtime 版本，
例如 `0.1.1-rc.2-ver1`。也可以创建并推送 `runtime-<version>` tag；workflow
会为 `darwin-arm64` 和 `darwin-x64` 分别构建，运行 smoke test，生成并签名
catalog，然后创建对应的 Runtime Release，并更新固定的 `runtime-catalog`
Release。

workflow 还会每小时检查 DeepSeek Harness 官方仓库的已发布 Release。匹配
`dsh-vX.Y.Z...` 的新版本会自动构造 `<HarnessVersion>-ver1`，例如
`dsh-v0.1.1-rc.2` 对应 `0.1.1-rc.2-ver1`，然后走同一套构建、验证和发布流程。
如果该 Runtime Release 已存在，本次检查会跳过，不会重复发布。手动
`workflow_dispatch` 输入和 `runtime-<version>` tag 触发仍然可用；手动重新构建
同一个 Harness 版本时可使用 `-ver2`、`-ver3` 等递增修订号。
