# DSH Studio Runtime

这个仓库把官方 DeepSeek Harness 及其完整依赖打包成**可验证、不可变、可回滚**的
macOS Runtime artifact，并用签名 catalog 发布给 DSH Studio 使用。App 仓库
[DSH Studio](https://github.com/SteveTanSaMa/DSH-Studio) 只保留 Runtime 发现、签名
校验、下载、安装、健康检查和回滚逻辑。

这里**不实现** Harness，也不包含任何 App/UI 代码：上游 Harness 是依赖，不是 fork。

## 架构

```text
DeepSeek Harness（官方 release tag dsh-vX.Y.Z / npm @deepseek-ai/dsh）
        │ 精确 pin 的版本
        ▼
DSH-Studio-Runtime
        ├── build       下载固定版本 Node，解析 Harness + pnpm 依赖
        ├── package     生成 archive：manifest.json + node/ + harness/
        ├── smoke test  在解包后的 artifact 上启动 Harness 并验证原生依赖
        ├── checksum    计算 SHA-256 并写入 catalog
        └── sign        Ed25519 签名 catalog
        │
        ▼
Signed Runtime Catalog（`runtime-catalog` release 中的 runtime-catalog.signed.json）
        │
        ▼
DSH Studio：验证签名 → 校验 SHA-256 → 安装 → 健康检查 → 失败自动回滚
```

## 版本身份

版本规则的权威说明见 [`docs/versioning.md`](docs/versioning.md)。要点：**Runtime 的公开版本号 =
官方 Harness 版本**；重新打包不产生新版本号，`SHA-256` 才是 artifact 身份。

```text
DeepSeek Harness 0.2.0-rc.1
        │
        ▼
Runtime 0.2.0-rc.1      ← 版本号 = Harness 版本（tag / 标题 / 文件名 / manifest / catalog）
        │
        ▼
SHA-256                 ← artifact 身份：重新打包换的是这个值，不是版本号
```

| 名称 | 含义 | 出现位置 |
| --- | --- | --- |
| `runtimeVersion` | 官方 Harness 版本，如 `0.2.0-rc.1`；它就是 Runtime 的唯一身份 | tag、标题、文件名、manifest、catalog |
| `platform` / `architecture` | `macos` / `darwin-arm64`、`darwin-x64` | manifest、catalog |
| `sha256` | 最终 artifact 的字节身份 | `artifact-*.json`、签名 catalog、release 附件 |
| `provenance`（commit、run id） | 构建过程信息，只用于追溯 | Release 正文、manifest |

**排序规则**（客户端 `RuntimeVersionOrdering.compare` 与 `check-catalog-precedent.sh` 一致，
按 semver 解析，不做字符串比较）：`0.2.0-rc.9 < 0.2.0-rc.10 < 0.2.0 < 0.2.1`。

### 一个 Harness 版本 = 一个当前有效的 Runtime

第一次打包发现问题时，**版本号不变**，重新打包并替换同一个 release 的附件：

```text
第一次构建   0.2.0-rc.1   SHA A
发现问题     0.2.0-rc.1   SHA B   → 发布 B：替换附件，catalog 指向 SHA B
```

- tag 仍然是 `runtime-0.2.0-rc.1`，标题仍然是 `Runtime 0.2.0-rc.1`；
- 不会出现 `runtime-0.2.0-rc.1-r2`、`-ver2`、`-rebuild-2`、`-revision-2` 这样的第二个 release；
- 起决定作用的是 **SHA-256**：客户端下载后按 catalog 里的 sha256 校验字节。

旧的失败构建属于构建历史，不是 Runtime 版本；catalog 与 release 只表达当前有效的那个 artifact。
需要长期留存的产物请另存归档，不要靠版本号区分。

### 重新打包的上传窗口

附件是逐个上传到 GitHub Release 的，所以在「新 tar 包已上传、catalog 还没更新」的窗口里，
客户端若拿缓存里的旧 catalog 校验新字节会**校验失败并 fail closed**，不会安装损坏的 Runtime。
流水线因此始终先上传产物、最后上传 catalog；重跑一次 dispatch 即可补完。

### 与旧版本号（`-verN`）的关系

仓库曾用 `<harness>-verN` 表示「同一 Harness 版本的第 N 次打包」，该后缀已退役：

- 新发布的 Runtime 一律使用纯 Harness 版本号；
- 客户端仍能解析旧形式并正确排序（同一 Harness 版本下 `-verN` 大于纯版本号，更新的 Harness
  版本则大于旧 Harness 的任何 `-verN`），所以线上现有的 `-verN` catalog 仍然可读；
- **本项目仍在开发阶段，没有需要迁移的存量安装**：第一次用纯版本号发布时，推荐先把开发期的
  旧 release 清掉再发，这样 catalog 守卫看到的是「首次发布」，无需任何特殊参数：

  ```bash
  # 一次性清理开发期产物（会删除 release 与其 tag，属破坏性操作，先确认再执行）
  gh release delete runtime-0.2.0-rc.1-ver1 --repo SteveTanSaMa/DSH-Studio-Runtime --yes --cleanup-tag
  gh release delete runtime-catalog      --repo SteveTanSaMa/DSH-Studio-Runtime --yes --cleanup-tag
  ```

  若想保留旧 release、直接覆盖 catalog，则那一次发布需要显式勾选 `allow_catalog_downgrade`
  （守卫会先把纯版本号当成一次「降级」而拒绝，并在报错里说明）。

### 展示与诊断

普通界面只显示 Harness 版本（`0.2.0-rc.1`）。构建过程信息留在 Release 正文、manifest 的
`provenance` 与 App 的诊断摘要里，不进入版本号，也不会出现「revison 2」这类看起来像官方
补丁号的写法。

## 仓库内容

| 文件 | 作用 |
| --- | --- |
| `.github/workflows/runtime-builder.yml` | 构建、验证、签名并发布 Runtime |
| `.github/workflows/verify.yml` | PR 门禁：离线测试套件（无 secret） |
| `Scripts/build-runtime.sh` | 构建单个架构的 Runtime artifact |
| `Scripts/runtime-smoke.sh` | 对解包后的 artifact 运行本地 smoke test |
| `Scripts/generate-runtime-catalog.sh` | 合并两个架构的 metadata 生成 catalog（并复核校验和） |
| `Scripts/check-catalog-precedent.sh` | 拒绝降级发布与替换已发布字节 |
| `Scripts/sign-runtime-catalog.sh` | 用 Ed25519 私钥签名 catalog |
| `Scripts/verify-runtime-catalog.sh` | 验证签名信封（失败即关闭） |
| `Scripts/verify-published-runtime.sh` | 发布后按客户端视角回下载验证 |
| `Scripts/resolve-plugin-market.js` | 解析与 Harness 兼容的插件市场版本（范围语义与客户端一致） |
| `Scripts/run-tests.sh` | 离线测试套件（fixture，不需要网络/密钥/macOS） |
| `keys/runtime-catalog-public.txt` | 公开的信任锚：keyID + Ed25519 公钥 |
| `docs/runtime-contract.md` | 与 DSH Studio 之间的契约（schema、URL、语义） |
| `docs/versioning.md` | 版本规则的权威说明（已冻结） |
| `docs/runtime-catalog-keys.md` | 私钥与 App 公钥的对应关系、轮换步骤 |

构建产物（压缩包、manifest、artifact metadata、catalog）只作为 GitHub Actions artifact
或 GitHub Release 资产发布，不提交到 Git。Runtime 不额外生成 `*.tar.gz.sha256` 文件；
GitHub Release 会显示每个附件的 SHA-256，而 artifact metadata 与签名 catalog 中都保留
SHA-256，供 DSH Studio 下载时自动校验。

## 固定输入

一个 `runtimeVersion` 必须唯一对应一份字节，所以构建输入都是显式 pin 的：

| 输入 | 来源 | 说明 |
| --- | --- | --- |
| Harness 版本 | 上游 release / npm，或 `harness_version` 输入 | 必须与版本字符串前缀一致 |
| Node 版本 | `Scripts/build-runtime.sh` 中的 `NODE_VERSION`（可用 `NODE_VERSION` 覆盖） | 用 nodejs.org 官方 `SHASUMS256.txt` 校验下载 |
| pnpm 版本 | 仓库变量 `RUNTIME_PNPM_VERSION` 或 `pnpm_version` 输入 | **必填**；缺失时构建直接失败 |
| npm registry | `NPM_REGISTRY`，默认 `https://registry.npmjs.org` | 写进 manifest |
| 依赖解析 | 构建时生成 `package-lock.json` 并 `npm ci` | lockfile 的 SHA-256 记录在 manifest 的 `dependencyLockSHA256` |
| 数据格式 | 仓库变量 `RUNTIME_DATA_FORMAT_ID` 等 | catalog 必须声明，否则客户端会阻塞更新 |
| 插件市场 pin | 构建时解析，可用 `PLUGIN_MARKET_VERSION` / dispatch 输入 `plugin_market_version` / 仓库变量 `RUNTIME_PLUGIN_MARKET_VERSION` 固定 | 见下节 |

本地实验可以设 `DSH_RUNTIME_ALLOW_UNPINNED_PNPM=1` 让 pnpm 解析 latest，但这类构建
**不可发布**（catalog 生成与发布流程都不接受）。

## Plugin Market pin

哪个插件市场版本能用，由这份 Runtime 里的 Harness 版本决定：市场按 `peerDependencies`
声明它支持的 Harness 范围，而运行中的 Harness 由 Runtime 决定。所以这个版本不是 App 里的
常量，而是随 Runtime 发布的数据——否则 Runtime 一升级，市场就跟不上了。

- `Scripts/resolve-plugin-market.js` 读取 registry 上 `dshmarket` 的全部版本，按每个版本
  自己声明的 Harness 范围（`@deepseek-ai/dsh-settings`，其次 `@deepseek-ai/dsh`）挑出覆盖
  当前 Harness 的版本：优先正式版，取其中最新的一个；没有正式版时才退而取预发布版；范围
  读不懂的版本直接跳过（发布出去的 pin 必须可验证）。
- 结果 `{package, version, integrity, harnessRange}` 写进 `manifest.json` 与 artifact
  metadata，再由 catalog 带给客户端。`integrity` 是 registry 上该版本的 `dist.integrity`，
  App 用它核对 profile 的 `pnpm-lock.yaml`。
- 兼容性判断在两侧使用同一套语义（App 的 `PluginCompatibility` ↔ `resolve-plugin-market.js`），
  `Scripts/run-tests.sh` 用同一批用例锁住两侧，避免「构建认为兼容、App 认为不兼容」。

需要人工介入时（dispatch 输入仅 `workflow_dispatch` 可用）：

| 情况 | 做法 |
| --- | --- |
| 固定一个市场版本 | `PLUGIN_MARKET_VERSION=1.66.5`，或 dispatch 输入 `plugin_market_version`，或仓库变量 `RUNTIME_PLUGIN_MARKET_VERSION`（显式指定的版本即使不兼容也会发布，并在日志里告警） |
| 上游刚发新 Harness、市场还没跟上 | `plugin_market_version=none`：明确不发布 pin，客户端回退到 App 编译内的兜底 pin，并如实报出「市场不支持当前 Harness」 |
| 跳过市场相关的 smoke 检查（离线环境） | `DSH_RUNTIME_SMOKE_SKIP_PLUGIN_MARKET=1` |

默认是**失败即停**：没有任何市场版本声明支持当前 Harness 时，构建直接失败并提示上面两条
出路，而不是悄悄发布一个用户装不上市场的 Runtime。

## 本地构建

```bash
RUNTIME_VERSION=0.2.0-rc.1 \
ARCHITECTURE=darwin-arm64 \
PNPM_VERSION=11.22.0 \
DSH_RUNTIME_DATA_FORMAT_ID=sqlite-v2 \
  ./Scripts/build-runtime.sh
```

流程：下载并校验 Node → 解析 Harness/pnpm → 编译原生模块（如 `fs-ext`）→ 生成
`manifest.json` → 打包 → 计算 SHA-256 → **解包到临时目录并运行 smoke test** → 写出
`RuntimeArtifacts/` 下的 artifact、manifest 与 metadata。

常用变量：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `OUTPUT_DIR` | `RuntimeArtifacts/` | 产物输出目录 |
| `WORK_DIR` | 临时目录 | 复用工作目录可保留下载缓存 |
| `NODE_VERSION` | 脚本内 pin | 覆盖打包的 Node 版本 |
| `NPM_REGISTRY` | npmjs | 换源 |
| `RUNTIME_ARTIFACT_BASE_URL` | GitHub release 地址 | 写入 metadata 的下载地址 |

## Smoke test

```bash
# 对一个已解包的 artifact（manifest.json + node/ + harness/）运行：
./Scripts/runtime-smoke.sh /path/to/extracted/runtime

# 对本机已安装的 Runtime 复跑也可以（旧命名 -verN 的安装目录同样适用）：
./Scripts/runtime-smoke.sh \
  "$HOME/Library/Application Support/DSH Studio/Runtimes/0.2.0-rc.1"
```

不需要账号或 API key，唯一需要网络的一步是按 manifest 里的 pin 把插件市场装进 scratch
profile（`DSH_RUNTIME_SMOKE_SKIP_PLUGIN_MARKET=1` 可以跳过）。检查内容：

1. manifest 可解析，且布局与 architecture 一致；
2. 打包的 Node / pnpm 可执行且版本与 manifest 相符；
3. `node`、`node-pty/pty.node`、`spawn-helper` 的 Mach-O 架构与 manifest 一致（x64 是在
   Apple Silicon runner 上通过 Rosetta 构建的，只看“能跑”会漏掉错架构）；
4. `node-pty`（以及存在的 `fs-ext`）能被打包的 Node 真正 dlopen；
5. 能用 pty 真实 spawn 一个进程并拿到输出（真正用到 spawn-helper）；
6. manifest 里带插件市场 pin 时，用 App 完全相同的方式在 scratch profile 里实装一次
   （`plugin --profile web add <package>@<version> --save-exact`），并核对 profile 的
   `package.json`、`node_modules` 版本、`pnpm-lock.yaml` 里的版本与 integrity；
7. Harness 能启动 `web --host 127.0.0.1 --port 0 --no-open`，完成 token 换取并回答
   `settings/describe`——因为第 6 步已经装好了市场，这一步同时也验证了「带着固定市场版本
   的 profile 能正常启动」；
8. 探测后进程仍存活，且收到 SIGTERM 后能正常退出（App 退出时就是这样停 Runtime 的）。

测试环境是隔离的：`HOME`、`XDG_*`、`DSH_HOME` 都指向临时目录，不会读写真实用户数据。

分层：

```text
Scripts/run-tests.sh        离线单测 + fixture 负例（PR 门禁，无 secret）
        ▼
runtime-smoke.sh            本地 smoke（构建时在解包产物上运行）
        ▼
verify-published-runtime.sh 发布后回下载验证（真实网络，只读，无 secret）
```

Smoke test 依赖 Harness 的 `web` 子命令和 `settings/describe` RPC，这两处属于内部协议，
上游变动会让构建失败（这是有意的 fail closed）。它**不**创建 session、不调用模型，因此
不需要账号或额度；代价是 native session 持久化路径只覆盖到“模块能加载”这一层。

## 发布如何发生

三种触发方式，最终都走同一条流水线：

- `workflow_dispatch`：手动输入 Harness 版本，例如 `0.2.0-rc.1`（重新打包同一版本时输入同一个值即可）；
- `runtime-<version>` tag push；
- 每小时 cron：检查上游 Harness release，为尚未生成 Runtime 的版本使用该 Harness 版本号
  （从 `0.1.1-rc.2` 之后按发布时间补齐；npm 包还没发布时跳过，等下次检查）。

流水线顺序：

```text
resolve exact Harness version
        ▼
build（每条架构各跑一次，含 smoke test）
        ▼
generate manifest（含 platform / dependencyLockSHA256 / provenance）
        ▼
package + SHA-256
        ▼
smoke test（在解包后的 artifact 上）
        ▼
generate catalog（复核 artifact 字节与校验和）
        ▼
check precedent（拒绝降级、拒绝替换已发布字节）
        ▼
sign catalog（Ed25519，信任锚必须匹配）
        ▼
publish artifacts → publish signed catalog（catalog 最后上传）
        ▼
verify-published（回下载公开 URL，验签 + 校验 SHA-256）
```

任何一步失败都不会产生可用的新 catalog。

Release 的**标题**就是 `Runtime <Harness 版本>`，**正文**由流水线自动生成：Harness 版本、
platform、Node/pnpm/dataFormat/插件市场 pin、依赖 lock 哈希、各架构的 SHA-256 与大小、构建
provenance（commit、run id），以及客户端实际使用的 catalog 地址——版本号里没有任何构建计数。

**失败自愈**：如果 release 已经创建但附件或 catalog 没传完，publish job 的清理步骤会删除
这个 release 和 tag，下一次 cron/dispatch 会重新构建，不会永久卡死。若需要人工介入：

```bash
gh release delete runtime-0.2.0-rc.1 --repo SteveTanSaMa/DSH-Studio-Runtime --yes --cleanup-tag
```

然后重新 dispatch 或等 cron。想要保留旧 release、只替换附件与 catalog，直接重新 dispatch 同一
版本即可：版本号不变，附加的 SHA-256 会更新。
`allow_catalog_downgrade`（仅 `workflow_dispatch`）用于有意回退 catalog 版本，不会允许
替换已发布字节。

## 签名与密钥

```text
catalog.json ──Ed25519 签名──▶ runtime-catalog.signed.json
                                      │
                                      ▼
                    DSH Studio 内置公钥（信任锚）验签
                                      │
                                      ▼
                       选中 Runtime → 下载 → 校验 SHA-256 → 安装
```

信封格式（`Scripts/sign-runtime-catalog.sh` 产出，客户端逐项校验）：

```json
{
  "schemaVersion": 1,
  "keyID": "runtime-catalog-v1",
  "payload": "<base64 的 catalog JSON>",
  "signature": "<base64 的 Ed25519 签名，签名对象是 payload 的原始字节>"
}
```

| 项目 | 位置 |
| --- | --- |
| 公钥（信任锚） | `keys/runtime-catalog-public.txt`，同一份值也在 App 的 `RUNTIME_CATALOG_PUBLIC_KEY`（`project.pbxproj`，Debug 与 Release） |
| 私钥 | GitHub Actions **environment secret** `RUNTIME_CATALOG_PRIVATE_KEY_BASE64`（environment：`runtime-signing`） |
| 轮换步骤 | [`docs/runtime-catalog-keys.md`](docs/runtime-catalog-keys.md) |

私钥永远不进 Git、不进 artifact、不进 CI 日志，也不经命令行参数传递（argv 对同机进程
可见，环境变量不是）。构建 job 本身不持有任何 secret，因此 artifact 不可能包含私钥。

关键不变量：**私钥派生出的公钥必须等于 `keys/runtime-catalog-public.txt`**。签名脚本会
校验，不匹配就拒绝签名——否则一次错误的轮换会让所有已发布 App 静默失去远程发现能力。
发布后的 `verify-published` job 还会用同一个公钥验证线上 catalog。

## 仓库配置（一次性）

仓库变量：

```text
RUNTIME_DATA_FORMAT_ID                必填，例如 sqlite-v2
RUNTIME_DATA_FORMAT_COMPATIBLE_WITH   可选，逗号分隔
RUNTIME_DATA_FORMAT_MIGRATION         可选
RUNTIME_PNPM_VERSION                  必填，例如 11.22.0
```

Environment 与 secret：

1. 创建 environment `runtime-signing`（`runtime-builder.yml` 的 publish job 引用它，
   不需要 required reviewers，自动发布保持无人值守）；
2. 在该 environment 中创建 secret `RUNTIME_CATALOG_PRIVATE_KEY_BASE64`（PKCS#8 DER 的
   base64）；构建 job 不引用该 environment，因此拿不到私钥。

## DSH Studio 如何消费 catalog

1. 从固定地址读取 `runtime-catalog.signed.json`，用内置公钥验签（`keyID` 必须等于
   `runtime-catalog-v1`，`schemaVersion` 必须等于 1），失败即关闭；
2. 解析 payload，按本机架构挑选 release，并校验 `runtimeVersion`、依赖 pin、数据格式与
   artifact 描述（URL 必须等于固定形状，`sha256` 必须是 64 位十六进制）；
3. 下载 artifact，校验 SHA-256，然后校验 archive 布局（只允许 `manifest.json`、`node/`、
   `harness/`）与 `manifest.json` 的 `schemaVersion: 3` 逐字段一致；
4. 安装到 `Runtimes/<runtimeVersion>`（不覆盖正在工作的 Runtime），启动后做健康检查
   （`settings/describe`，默认 90s 启动超时 + 5s 请求超时）；
5. 健康检查失败自动回滚到上一个 known-good Runtime，回滚完全离线；
6. 数据兼容性：新 Runtime 声明了不兼容的 `dataFormat.id` 时会新建隔离 profile，旧数据
   不会被迁移、覆盖或删除；没有声明 `dataFormat` 时直接阻塞更新（这也是 catalog 强制
   要求 `dataFormat` 的原因）。

细节见 [`docs/runtime-contract.md`](docs/runtime-contract.md)。

## 已知限制

- **不宣称字节级可复现**：传递依赖仍由 registry 解析，打包时间戳等也随构建变化。
  身份与完整性靠“catalog 记录实际 artifact 的 SHA-256 + 客户端逐字节校验（失败即关闭）”
  保证，而不是靠重建结果一致。`dependencyLockSHA256` 与 `provenance` 让每次发布可追溯。
- x64 Runtime 在 Apple Silicon runner 上通过 Rosetta 构建与验证，靠 `lipo -archs` 断言
  架构，但没有真实 Intel 机器上的运行验证。
- smoke test 覆盖到“能启动、能回答 RPC、原生依赖可用、能优雅退出”，以及“按 pin 装好插件市场
  后 Harness 能带着它启动”；市场自身的 HTTP 路由与界面交互仍由 App 在使用时验证。
- 上游 Harness 的 `web` 子命令或 `settings/describe` RPC 变化会导致构建失败，需要同步
  更新 `Scripts/runtime-smoke.sh`（历史上已发生过一次）。
- 历史 Runtime release 不会被清理：客户端本地缓存可能仍引用它们。
