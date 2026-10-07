# DSH Studio Runtime

[English](README.en.md) | **中文**

本仓库负责把官方 DeepSeek Harness 及其完整依赖，打包成**可验证、不可变、可回滚**的 macOS
Runtime artifact，并以签名 catalog 发布。客户端仓库
[DSH Studio](https://github.com/SteveTanSaMa/DSH-Studio) 只负责 Runtime 的发现、验签、下载、
校验、安装、健康检查与回滚。

**范围**

- 本仓库不实现 Harness，也不包含任何 App/UI 代码；官方 Harness 是依赖，不是 fork。
- 本仓库不提供更新服务；客户端读取的是 GitHub Release 上的静态资产。
- 本仓库不保存已发布的 artifact；GitHub Release 是唯一分发渠道。

**规范用词**：本文中「必须」表示违反即失败（fail closed），「不允许」表示对应操作会被工具或
流水线拒绝，「应当」表示约定，偏离时需要说明理由。

## 目录

- [1. 流水线](#1-流水线)
- [2. 版本身份](#2-版本身份)
- [3. 产物与命名](#3-产物与命名)
- [4. 发布](#4-发布)
- [5. 签名与密钥](#5-签名与密钥)
- [6. 仓库配置](#6-仓库配置)
- [7. 本地构建](#7-本地构建)
- [8. 验证与测试](#8-验证与测试)
- [9. DSH Studio 如何消费](#9-dsh-studio-如何消费)
- [10. 已知限制](#10-已知限制)
- [11. 文档索引](#11-文档索引)

## 1. 流水线

```text
DeepSeek Harness（官方 release tag dsh-v<version> / npm @deepseek-ai/dsh@<version>）
        │ 精确 pin 的版本
        ▼
DSH-Studio-Runtime
        ├── build       下载固定版本 Node，解析 Harness 与 pnpm 依赖
        ├── package     生成 archive：manifest.json + node/ + harness/
        ├── smoke test  在解包后的 artifact 上启动 Harness 并验证原生依赖
        ├── checksum    计算 artifact 的 SHA-256
        └── sign        用 Ed25519 签名 catalog
        │
        ▼
签名 catalog（release `runtime-catalog` 中的 runtime-catalog.signed.json）
        │
        ▼
DSH Studio：验签 → 校验 SHA-256 → 解包校验 → 安装 → 健康检查 → 失败则回滚
```

## 2. 版本身份

权威规则见 [`docs/versioning.md`](docs/versioning.md)。摘要如下。

```text
DeepSeek Harness 0.2.0-rc.1
        │
        ▼
Runtime 0.2.0-rc.1      ← 版本号 = Harness 版本（tag / 标题 / 文件名 / manifest / catalog）
        │
        ▼
SHA-256                 ← artifact 身份：重新打包改变的是这个值，不是版本号
```

| 名称 | 含义 | 出现位置 |
| --- | --- | --- |
| `runtimeVersion` | 官方 Harness 版本（如 `0.2.0-rc.1`）；Runtime 的唯一版本身份 | tag、标题、文件名、manifest、catalog |
| `platform` / `architecture` | `macos` / `darwin-arm64`、`darwin-x64` | manifest、catalog |
| `sha256` | 最终 artifact 的字节身份 | `artifact-*.json`、签名 catalog、release 附件 |
| `provenance` | 构建来源（commit、run id），仅用于追溯 | Release 正文、manifest |

### 不变量

1. `runtimeVersion` 必须等于官方 Harness 版本，不允许附加构建计数（`-verN`、`-rN`、
   `-rebuild-N`、`-revision-N` 均被构建脚本与 catalog 生成器拒绝）。
2. 同一 `runtimeVersion` 只对应一个当前有效的 Runtime；重新打包沿用同一版本号、tag 与文件名，
   替换附件并更新 catalog 中的 `sha256`。
3. artifact 身份由 `catalog` 记录的 `sha256` 与 `size` 决定；客户端下载后逐字节校验，不一致即
   拒绝安装。
4. tag、附件名与下载 URL 的形状必须与客户端约定一致（`docs/runtime-contract.md` 第 1、2 节）；
   改动它们会让已发布的 App 拒绝该 catalog。

### 排序规则

版本按 semver 解析比较，不做字符串比较：`0.2.0-rc.9 < 0.2.0-rc.10 < 0.2.0 < 0.2.1`。
客户端 `RuntimeVersionOrdering.compare` 与 `Scripts/check-catalog-precedent.sh` 必须保持同一
语义，避免发布端与客户端对「更新」的判断不一致。

### 展示与诊断

用户可见的版本号只有 Harness 版本。构建过程信息（commit、run id）写在 Release 正文与 manifest
的 `provenance` 中，不进入版本号，也不出现在用户界面的版本位置。

### 历史形式（已退役）

仓库曾使用 `<harnessVersion>-verN` 表示同一 Harness 版本的第 N 次打包。该形式已退役：

- 发布侧不再接受它：`Scripts/build-runtime.sh` 与 `Scripts/generate-runtime-catalog.sh` 都会拒绝
  携带构建计数的版本输入；
- 已发布的 `-verN` release 与 catalog 均已清理，仓库中不存在该形式的产物；
- `Scripts/check-catalog-precedent.sh` 不再为它保留解析分支：Runtime 版本即 Harness 版本，按
  第 2 节的排序规则比较。

## 3. 产物与命名

### 命名

| 对象 | 规则 | 示例 |
| --- | --- | --- |
| Runtime release tag | `runtime-<runtimeVersion>` | `runtime-0.2.0-rc.2` |
| Runtime release 标题 | `Runtime <runtimeVersion>` | `Runtime 0.2.0-rc.2` |
| 架构 artifact | `dsh-runtime-<runtimeVersion>-<architecture>.tar.gz` | `dsh-runtime-0.2.0-rc.2-darwin-arm64.tar.gz` |
| 安装 manifest 附件 | `manifest-<runtimeVersion>-<architecture>.json` | — |
| artifact metadata | `artifact-<runtimeVersion>-<architecture>.json` | — |
| 未签名 catalog payload | `runtime-release.json` | — |
| catalog release | tag `runtime-catalog`，资产 `runtime-catalog.signed.json` | — |

Runtime 不额外生成 `*.tar.gz.sha256`：Release 页面会显示每个附件的 SHA-256，metadata 与签名
catalog 中也记录 SHA-256 供客户端自动校验。

### archive 布局

archive 根目录只允许以下条目；出现其他条目（包括 macOS 的 `.DS_Store`、AppleDouble `._*`）会让
客户端拒绝整个 artifact：

```text
manifest.json
node/<architecture>/...
harness/<architecture>/<harnessVersion>/...
```

### manifest（archive 内，`schemaVersion: 3`）

`schemaVersion`、`runtimeVersion`、`platform`、`architecture`、`nodeVersion`、`harnessVersion`、
`pnpmVersion`、`nodeSHA256`、`harnessPackageIntegrity`、`pnpmPackageIntegrity`、`registry`、
`dependencyLockSHA256`、`pluginMarket`、`dataFormat`、`provenance`。

客户端会把这组字段与签名 catalog 中的对应条目逐字段比对；新增字段是兼容的（客户端忽略未知
字段），修改或删除已有字段的语义不兼容。artifact 自身的 `sha256`/`size` 不写在 archive 内
（那会构成循环定义），而由 metadata 与签名 catalog 表达。

### catalog（签名 payload，`schemaVersion: 1`）

`runtimeVersion`，以及每个架构一条 `releases[]`：`runtimeVersion`、`platform`、`architecture`、
`nodeVersion`、`harnessVersion`、`pnpmVersion`、`nodeArchiveSHA256`、
`harnessPackageIntegrity`、`pnpmPackageIntegrity`、`dependencyLockSHA256`、`pluginMarket`、
`dataFormat`、`artifact`（`runtimeVersion`、`architecture`、`url`、`sha256`、`size`）。

### 签名信封（`schemaVersion: 1`）

```json
{
  "schemaVersion": 1,
  "keyID": "runtime-catalog-v1",
  "payload": "<base64 编码的 catalog JSON>",
  "signature": "<base64 编码的 Ed25519 签名，签名对象是 payload 的原始字节>"
}
```

## 4. 发布

### 触发方式

| 触发 | 说明 |
| --- | --- |
| `workflow_dispatch` | 手动输入 Harness 版本（如 `0.2.0-rc.1`）。重新打包同一版本时输入同一值，附件会被替换 |
| `runtime-<version>` tag push | 与 dispatch 等价；`runtime-catalog` tag 被显式排除，避免自触发 |
| 每小时 cron | 扫描上游 `dsh-v*` release（按发布时间升序）：已存在 `runtime-<version>` release 的版本跳过；npm 上未发布 `@deepseek-ai/dsh@<version>` 的版本跳过并告警；否则构建该版本并结束本次运行（每次最多发布一个版本） |

`UPSTREAM_MIN_HARNESS_VERSION`（当前 `0.1.7-rc.2`）及其之前的版本被视为已处理，轮询从
`0.2.0-rc.1` 起。该下限必须停在最后一个不可重建的版本上，否则轮询会反复尝试构建一个必然失败的
旧版本，且永远不会到达更新的版本（原因见 [`docs/historical-versions.md`](docs/historical-versions.md)）。

### 流水线顺序

```text
resolve exact Harness version
        ▼
build（每条架构各跑一次）
        ▼
audit dependencies（依赖闭包新增未登记的 install / native 构建脚本 → 失败）
        ▼
generate manifest（platform / dependencyLockSHA256 / provenance / pluginMarket / dataFormat）
        ▼
package + SHA-256
        ▼
smoke test（在解包后的 artifact 上运行）
        ▼
generate catalog（复核 artifact 字节、大小与校验和）
        ▼
check precedent（拒绝降级；同版本重新打包在此报告替换）
        ▼
sign catalog（Ed25519，必须匹配信任锚）
        ▼
upload artifacts → upload signed catalog（catalog 最后上传）
        ▼
verify-published（从公开 URL 重新下载，验签并校验 SHA-256）
```

任何一步失败都不会产生新的可用 catalog。

### 拒绝条件（fail closed）

| 条件 | 结果 |
| --- | --- |
| `RUNTIME_VERSION` 不是合法 Harness 版本，或含构建计数 | 构建失败 |
| `PNPM_VERSION` 未提供 | 构建失败 |
| Node 归档与其官方 `SHASUMS256.txt` 不符 | 构建失败 |
| 没有任何插件市场版本声明支持该 Harness | 构建失败（除非显式 `none`，见第 7 节） |
| 依赖闭包出现未登记的 install / native 构建脚本 | 构建失败 |
| smoke test 任一断言失败 | 构建失败 |
| artifact 字节与其 metadata 的 `sha256`/`size` 不符 | catalog 生成失败 |
| 已发布的 catalog 验签失败 | 发布失败 |
| 新 catalog 版本低于已发布版本 | 发布失败（除非显式 `allow_catalog_downgrade`） |
| 私钥派生的公钥与 `keys/runtime-catalog-public.txt` 不符 | 签名失败 |

### 失败处理

- publish job 会记录「本次运行是否创建了 release」。若在 catalog 上传完成之前失败，运行会删除
  **本次创建的** release 与 tag，使后续 cron 或 dispatch 能够重建该版本；若失败发生在 release
  创建之前，则不做任何删除。
- catalog 上传完成后即视为发布成功，之后的步骤失败不会回滚已发布的内容。
- 需要人工干预时（例如必须废弃某个版本）：

  ```bash
  gh release delete runtime-0.2.0-rc.1 --repo SteveTanSaMa/DSH-Studio-Runtime --yes --cleanup-tag
  ```

  删除后重新 dispatch 或等待 cron；如果只想替换附件与 catalog，直接重新 dispatch 同一版本即可。

- 附件是逐个上传的，因此存在「新 tar 包已上传、catalog 尚未更新」的窗口。该窗口内客户端若用
  缓存中的 catalog 校验新字节会失败并拒绝安装（fail closed），不会安装损坏的 Runtime。

- 若运行在创建 `runtime-catalog` release 之后、上传 catalog 之前被打断，release 会存在但没有
  catalog 资产。这种状态不会阻塞后续发布：下一次发布按「尚无已发布 catalog」处理并写入签名
  catalog 修复它。验签没有被削弱——资产存在但验签失败时仍然拒绝发布。
- Releases 列表的顺序由**发布时间**决定，与 Latest 徽章无关。`runtime-catalog` 只在第一次创建
  （早于所有 runtime），之后每次发布只替换它的资产，发布时间不变，因此它永远排在列表最下面；
  新发布的 runtime 永远在最上面。流水线**不再**手动改 Latest 徽章：徽章由 GitHub 自动给最新的
  release（也就是人打开仓库想看的那个 runtime）。客户端不读徽章，也不读 `releases/latest`，
  它只读固定 URL 上的签名 catalog，所以徽章指向哪里都不影响更新。

### 更新安全（客户端语义）

客户端更新 Runtime 的顺序是：

```text
download → verify（签名 + SHA-256 + size）→ extract → validate（manifest 与 catalog 一致）
        → launch → health check（settings/describe）→ activate
```

**activate 必须是最后一步**：`download`、`verify`、`extract`、`validate`、`launch`、`health check`
任一阶段失败，都只能丢弃新 Runtime，正在使用（known-good）的旧 Runtime 必须原样保留。

本仓库不是安装器：安装、promote、回滚、崩溃恢复都由 DSH Studio 实现，本仓库负责「不破坏这些
语义」——只发布经过签名与校验的字节（catalog 记录的 `sha256` 是唯一身份），同版本重新打包只替换
release 附件，从不要求客户端删除旧 Runtime。因此上表中安装/回滚类的故障注入只能在 App 侧做；
本仓库能自证的部分（校验和不符、损坏 archive、manifest 与布局不符、catalog 不降级、进程树残留）
都在 `Scripts/run-tests.sh` 与 `Scripts/runtime-smoke.sh` 里，详见第 8 节。

## 5. 签名与密钥

```text
catalog payload ──Ed25519 签名──▶ runtime-catalog.signed.json
                                          │
                                          ▼
                        DSH Studio 内置公钥（信任锚）验签
                                          │
                                          ▼
                        选择 Runtime → 下载 → 校验 SHA-256 → 安装
```

| 项目 | 位置 |
| --- | --- |
| 公钥（信任锚） | [`keys/runtime-catalog-public.txt`](keys/runtime-catalog-public.txt)；同一份值也内置于 App 的 `RUNTIME_CATALOG_PUBLIC_KEY`（Debug 与 Release） |
| 私钥 | GitHub Actions environment `runtime-signing` 中的 secret `RUNTIME_CATALOG_PRIVATE_KEY_BASE64` |
| 轮换步骤 | [`docs/runtime-catalog-keys.md`](docs/runtime-catalog-keys.md) |

**不变量**：私钥派生出的公钥必须等于 `keys/runtime-catalog-public.txt`；`sign-runtime-catalog.sh`
在签名前校验这一点，不匹配即拒绝签名。发布后的 `verify-published` job 用同一公钥验证线上
catalog。任何一次错误的轮换都会让已发布的 App 拒绝全部 catalog。

**私钥约束**：私钥不允许进入 Git、artifact、CI 日志或命令行参数（argv 对同机进程可见；环境变量
不可见）。构建 job 不引用 `runtime-signing` environment，因此不具备访问私钥的能力，artifact 中
不可能包含私钥。

## 6. 仓库配置

仓库变量：

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `RUNTIME_PNPM_VERSION` | 是 | 打包进 Runtime 的 pnpm 版本，例如 `11.22.0` |
| `RUNTIME_DATA_FORMAT_ID` | 是 | catalog 声明的数据格式 ID，例如 `sqlite-v2` |
| `RUNTIME_DATA_FORMAT_COMPATIBLE_WITH` | 否 | 逗号分隔的兼容旧格式 ID |
| `RUNTIME_DATA_FORMAT_MIGRATION` | 否 | 迁移标识；客户端不会自动执行迁移 |
| `RUNTIME_PLUGIN_MARKET_VERSION` | 否 | 固定插件市场版本；留空则按 Harness 版本解析 |

Environment 与 secret：

1. 创建 environment `runtime-signing`（publish job 引用；不需要 required reviewers，自动发布保持
   无人值守）。
2. 在其中创建 secret `RUNTIME_CATALOG_PRIVATE_KEY_BASE64`（PKCS#8 DER 的 base64）。

## 7. 本地构建

```bash
RUNTIME_VERSION=0.2.0-rc.1 \
ARCHITECTURE=darwin-arm64 \
PNPM_VERSION=11.22.0 \
DSH_RUNTIME_DATA_FORMAT_ID=sqlite-v2 \
  ./Scripts/build-runtime.sh
```

流程：下载并校验 Node → 解析 Harness 与 pnpm 依赖 → 编译原生模块（如 `fs-ext`）→ 生成
`manifest.json` → 打包 → 计算 SHA-256 → 解包到临时目录并运行 smoke test → 在 `OUTPUT_DIR`
写出 artifact、manifest 与 metadata。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `RUNTIME_VERSION` | 必填 | Harness 版本，同时是 Runtime 版本 |
| `ARCHITECTURE` | 本机架构 | `darwin-arm64` 或 `darwin-x64` |
| `PNPM_VERSION` | 无 | 必填；未提供则失败（见下） |
| `HARNESS_VERSION` | 等于 `RUNTIME_VERSION` | 若显式提供，必须与 `RUNTIME_VERSION` 相同 |
| `DSH_RUNTIME_DATA_FORMAT_ID` | 空 | 写入 manifest 的 `dataFormat.id` |
| `NODE_VERSION` | 脚本内 pin | 打包的 Node 版本 |
| `NPM_REGISTRY` | `https://registry.npmjs.org` | 依赖来源，写入 manifest |
| `OUTPUT_DIR` | `RuntimeArtifacts/` | 产物输出目录 |
| `WORK_DIR` | 临时目录 | 复用可保留下载与安装缓存 |
| `RUNTIME_ARTIFACT_BASE_URL` | GitHub Release 地址 | 写入 metadata 的下载地址 |
| `PLUGIN_MARKET_VERSION` | 自动解析 | 固定插件市场版本；`none` 表示不发布 pin |
| `DSH_RUNTIME_ALLOW_UNPINNED_PNPM=1` | 关闭 | 允许本地构建解析 pnpm 最新版；此类构建不可发布 |
| `DSH_RUNTIME_ALLOW_MISSING_PLUGIN_MARKET=1` | 关闭 | 允许不发布插件市场 pin |

插件市场 pin：哪个市场版本可用由该 Runtime 中的 Harness 版本决定，因此 pin 随 Runtime 发布，
而不是编译进 App。`Scripts/resolve-plugin-market.js` 读取 registry 上各版本的
`peerDependencies` 声明（`@deepseek-ai/dsh-settings`，其次 `@deepseek-ai/dsh`），选取覆盖当前
Harness 的最新正式版（无正式版时才退而取预发布版）；范围无法解析的版本一律跳过。结果
`{package, version, integrity, harnessRange}` 写入 manifest、metadata 与 catalog。默认行为是失败
即停：没有任何版本声明支持该 Harness 时构建失败，可用 `PLUGIN_MARKET_VERSION` 指定版本，或
`none` 明确不发布 pin（客户端退回其内置的兜底 pin 并如实报告不兼容）。

## 8. 验证与测试

分三层，成本与覆盖面递增：

```text
Scripts/run-tests.sh         离线测试（fixture；不需要网络、密钥或 macOS）— PR 门禁
        ▼
Scripts/runtime-smoke.sh     本地 smoke（构建时对解包后的 artifact 运行）
        ▼
Scripts/verify-published-runtime.sh   发布后从公开 URL 回下载验证（只读，无 secret）
```

`Scripts/run-tests.sh` 覆盖：版本解析与构建输入校验、catalog 与 metadata 规则（含 `dataFormat`、
`pluginMarket`、`sha256`、`size`、跨架构契约一致性）、catalog 不降级、签名与信封校验、依赖闭包
审计、插件市场范围语义与解析规则、进程树清理（真实进程，见
`Scripts/tests/process-tree-scenarios.sh`）、以及针对损坏 artifact 的负例。

测试分两层，PR 不会被拖慢：

| 层 | 何时运行 | 内容 |
| --- | --- | --- |
| 快（约 20s，离线、无密钥） | 每个 PR 与 main push（`verify.yml`） | `Scripts/run-tests.sh` 全部 fixture 与进程清理场景 |
| 重（需要网络与签名环境） | 发布流程、手动 dispatch、cron（`runtime-builder.yml`） | 真实构建两个架构 → 对解包后的 artifact 跑 smoke → 签名发布 → 从公开 URL 回下载验证 |

smoke test 的检查项：

1. manifest 可解析，布局与 `architecture` 一致；
2. 打包的 Node 与 pnpm 可执行，版本与 manifest 相符；
3. `node`、`node-pty/pty.node`、`spawn-helper` 的 Mach-O 架构与 manifest 一致（x64 在 Apple
   Silicon runner 上通过 Rosetta 构建，仅验证「能运行」会漏掉错架构）；
4. `node-pty` 与（若存在）`fs-ext`、`koffi` 能被打包的 Node 真正加载（后两者的原生二进制来自
   平台相关的 optional dependency，装错架构只有加载时才暴露）；
5. 安全相关的封装随 artifact 存在且能被打包的 Node 加载：`@deepseek-ai/dsh-sandbox-local`、
   `-sandbox-policy`（三个模式名未被改名）、`dsh-credentials-local`；同时断言 `koffi` 的已安装
   版本与上游写的精确 pin 一致（Harness 唯一的原生运行时依赖，不能静默换版本）；
6. 能用 pty 实际启动进程并取得输出（真正使用 `spawn-helper`）；
7. 若 manifest 带有插件市场 pin，用与 App 相同的方式在 scratch profile 中安装并核对
   `package.json`、`node_modules` 版本与 `pnpm-lock.yaml` 中的版本和 integrity；
8. Harness 能启动 `web --host 127.0.0.1 --port 0 --no-open`，完成 token 换取并回答
   `settings/describe`；该步骤同时验证「带固定市场版本的 profile 能正常启动」；
9. 探测后进程仍存活，并在收到 SIGTERM 后正常退出；
10. 启动期间在 Harness 下观察到过的子进程（Harness 可能 fork 自身的 host 进程）全部退出，
    不留 orphan。

smoke test 不需要账号或 API key。唯一需要网络的是第 7 步（安装插件市场），可用
`DSH_RUNTIME_SMOKE_SKIP_PLUGIN_MARKET=1` 跳过。运行环境隔离：`HOME`、`XDG_*`、`DSH_HOME` 均
指向临时目录，不读写真实用户数据。该步骤的 install 脚本策略与 App 一致（禁用），见
`docs/runtime-contract.md` 第 3 节。

**不覆盖**：不创建 session、不调用模型、不验证插件市场自身的 HTTP 路由与界面交互；也不执行真实的
受限命令，因此「客户端机器上 Seatbelt 是否可用」只能由客户端在真实运行环境中判定，见
[`docs/runtime-contract.md`](docs/runtime-contract.md) 第 8 节。

## 9. DSH Studio 如何消费

1. 从固定地址读取 `runtime-catalog.signed.json`，用内置公钥验签（`keyID` 必须为
   `runtime-catalog-v1`，`schemaVersion` 必须为 1），失败即关闭；
2. 解析 payload，按本机架构选择 release，校验 `runtimeVersion`、依赖 pin、数据格式与 artifact
   描述（URL 必须等于固定形状，`sha256` 必须为 64 位十六进制）；
3. 下载 artifact，校验 SHA-256，再校验 archive 布局与 `manifest.json`（`schemaVersion: 3`）与
   catalog 条目逐字段一致；
4. 安装到 `Runtimes/<runtimeVersion>`（不覆盖正在运行的 Runtime），启动后做健康检查
   （`settings/describe`；默认启动超时 90s、请求超时 5s）；
5. 健康检查失败时自动回滚到上一个 known-good Runtime，回滚完全离线；
6. 数据兼容性：新 Runtime 声明了不兼容的 `dataFormat.id` 时新建隔离 profile，旧数据不会被迁移、
   覆盖或删除；未声明 `dataFormat` 时阻塞更新（因此 catalog 要求该字段必填）。

完整字段与语义见 [`docs/runtime-contract.md`](docs/runtime-contract.md)（中文）。

## 10. 已知限制

- **历史 Harness 版本无法重建**：每次构建都重新解析依赖图，宽松的依赖范围会解析出该版本发布
  之后才出现的传递依赖，形成不稳定的混合图。实测 0.1.5 之前的多个版本今天已无法启动，因此正式
  发布从 `0.2.0-rc.1` 开始。证据见 [`docs/historical-versions.md`](docs/historical-versions.md)。
- **不宣称字节级可复现**：传递依赖由 registry 解析，打包时间戳等也随构建变化。身份与完整性依靠
  「catalog 记录实际 artifact 的 SHA-256 + 客户端逐字节校验」，而不是重建结果一致；
  `dependencyLockSHA256` 与 `provenance` 用于追溯每次发布。
- **x64 Runtime 未经真实 Intel 机器验证**：构建与测试都在 Apple Silicon runner 上通过 Rosetta
  完成，架构由 `lipo -archs` 断言。当前覆盖：

  | 环境 | 状态 |
  | --- | --- |
  | Apple Silicon 原生执行 | 已支持，并在每次构建中执行 |
  | x86_64 Mach-O 架构校验（`lipo`） | 已测试 |
  | Apple Silicon 上通过 Rosetta 执行 x86_64 | 已测试 |
  | 真实 Intel Mac 硬件 | 当前不可用（不加 workaround） |
- **smoke test 依赖上游内部协议**：`web` 子命令或 `settings/describe` RPC 变化会导致构建失败
  （有意 fail closed），需要同步更新 `Scripts/runtime-smoke.sh`；历史上已发生过一次。
- **历史 release 不清理**：客户端本地缓存可能仍引用它们。

## 11. 文档索引

| 文档 | 内容 |
| --- | --- |
| [`docs/versioning.md`](docs/versioning.md) | 版本规则（权威、已冻结） |
| [`docs/runtime-contract.md`](docs/runtime-contract.md) | 与客户端之间的 URL、schema 与语义契约 |
| [`docs/runtime-catalog-keys.md`](docs/runtime-catalog-keys.md) | 签名密钥的对应关系与轮换步骤 |
| [`docs/historical-versions.md`](docs/historical-versions.md) | 可重建范围与依赖漂移证据 |

| 工具 | 作用 |
| --- | --- |
| `.github/workflows/runtime-builder.yml` | 构建、验证、签名与发布 Runtime |
| `.github/workflows/verify.yml` | PR 门禁：离线测试套件（无 secret） |
| `Scripts/build-runtime.sh` | 构建单个架构的 artifact |
| `Scripts/audit-dependencies.js` | 拒绝依赖闭包中未登记的 install / native 构建脚本 |
| `Scripts/runtime-smoke.sh` | 对解包后的 artifact 运行本地 smoke test |
| `Scripts/lib/process-tree.sh` | 进程树记录、断言与 best-effort 清理（smoke 与测试共用） |
| `Scripts/tests/process-tree-scenarios.sh` | 用真实进程验证清理语义的场景 |
| `Scripts/generate-runtime-catalog.sh` | 合并两个架构的 metadata 生成 catalog |
| `Scripts/check-catalog-precedent.sh` | 拒绝 catalog 降级，报告同版本重新打包 |
| `Scripts/sign-runtime-catalog.sh` | 用 Ed25519 私钥签名 catalog |
| `Scripts/verify-runtime-catalog.sh` | 校验签名信封并解码 payload |
| `Scripts/verify-published-runtime.sh` | 发布后按客户端视角回下载验证 |
| `Scripts/resolve-plugin-market.js` | 解析与 Harness 兼容的插件市场版本 |
| `Scripts/run-tests.sh` | 离线测试套件 |
