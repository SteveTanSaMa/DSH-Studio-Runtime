# Runtime contract with DSH Studio

这份文档固定的是**发布端必须遵守的契约**。客户端（DSH Studio）会逐项校验下面的内容，
任何不兼容改动都会让已发布的 App 拒绝安装或无法更新 Runtime。改动前请先确认客户端
实现：`DSH Studio/Sources/Runtime/Catalog/`、`Sources/Runtime/Installation/`、
`Sources/Runtime/Data/`。

## 0. 版本身份模型

Runtime 的公开版本号**就是它包含的官方 Harness 版本**，不含任何构建计数。三个层级、三个归属：

```text
upstream identity        runtimeVersion = harnessVersion    官方 Harness，例如 0.2.0-rc.1
        │                （本仓库不重新解释、不补 patch、不加 build 元数据）
        ▼
runtime release identity (runtimeVersion, platform, architecture)   这一次发布的对象
        │
        ▼
artifact identity        artifact.sha256                     最终 .tar.gz 的字节身份
```

| 层级 | 字段 | 谁拥有 | 何时变化 |
| --- | --- | --- | --- |
| upstream | `runtimeVersion` / `harnessVersion` | 官方 DeepSeek Harness | 只有上游发新版才变；两者永远相同 |
| release | `platform` / `architecture` | 本仓库 | 每个平台/架构各一个 artifact |
| artifact | `artifact.sha256` / `size` / `url` | 构建产物本身 | 每次打包都变；这是唯一的字节身份，版本号不能代替它 |

**排序规则**是全部版本判断的基础，客户端 `RuntimeVersionOrdering.compare` 与本仓库
`Scripts/check-catalog-precedent.sh` 必须保持一致（按 semver 解析，不做字符串比较）：

1. core 版本：`0.2.0 < 0.2.1`；
2. 同一 core 的预发布低于正式版：`0.2.0-rc.10 < 0.2.0`；
3. 预发布标识符按数值再按字典序：`0.2.0-rc.9 < 0.2.0-rc.10`。

**一个 Harness 版本 = 一个当前有效的 Runtime**。重新打包不产生新版本号：

```text
0.2.0-rc.1  SHA A   ──发现问题──▶  0.2.0-rc.1  SHA B      （同一个 tag、同一个文件名、同一个 URL）
```

- tag `runtime-0.2.0-rc.1`、标题 `Runtime 0.2.0-rc.1`、附件名
  `dsh-runtime-0.2.0-rc.1-<architecture>.tar.gz` 都不变；
- 起决定作用的是 SHA-256：客户端按 catalog 里的 sha256 校验下载到的字节；
- 不会出现 `-r2` / `-ver2` / `-rebuild-2` / `-revision-2` 之类的第二版本体系。

**资产替换窗口**：附件是逐个上传的，因此存在「新 tar 包已上传、catalog 尚未更新」的短暂窗口。
客户端此时用缓存 catalog 里的旧 sha256 校验新字节会失败并 **fail closed**（不安装）。流水线
因此始终先上传产物、最后上传 catalog。

**与旧 `-verN` 形式的关系**：仓库曾用 `<harness>-verN` 表示同一 Harness 版本的第 N 次打包，
该后缀已退役，但客户端仍能解析它并正确排序——同一 Harness 版本下 `-verN` 大于纯版本号，
更新的 Harness 版本则大于旧 Harness 的任何 `-verN`。本项目仍在开发阶段，没有需要迁移的存量
安装：第一次用纯版本号发布时，可以先删除开发期的旧 release 与 catalog 再做首次发布（守卫会
视为「首次发布」，不需要任何参数），也可以保留旧 release、用 `allow_catalog_downgrade` 显式
确认这一次覆盖。

## 1. URL 契约（客户端硬编码）

```text
catalog : https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-catalog/runtime-catalog.signed.json
artifact: https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-<runtimeVersion>/dsh-runtime-<runtimeVersion>-<architecture>.tar.gz
```

- 客户端只接受这两个形状（catalog 校验 host/path；artifact 校验路径完全相等），catalog
  里写的任何其他 URL 都会被拒绝。因此**不能**重命名 release tag、附件名或换域名。
- 客户端只从仓库内这两个地址取数据，不提供用户可配置的镜像。

上面的路径由 catalog 的 `runtimeVersion` 直接拼出（`RuntimeReleaseCatalog.isTrustedArtifactURL`），
所以 tag 与附件名只能是**该版本号本身**：`runtime-<版本号>` 与
`dsh-runtime-<版本号>-<architecture>.tar.gz`。版本号不含任何构建计数，因此重新打包只会替换
这些固定路径下的字节，不会产生新的路径。

## 2. 签名信封（`schemaVersion: 1`）

```json
{
  "schemaVersion": 1,
  "keyID": "runtime-catalog-v1",
  "payload": "<base64>",
  "signature": "<base64>"
}
```

| 字段 | 客户端行为 |
| --- | --- |
| `schemaVersion` | 必须等于 1，否则拒绝（fail closed） |
| `keyID` | 必须等于 App 内置的 `RuntimeCatalogTrust.keyID`（`runtime-catalog-v1`） |
| `payload` | base64 解码后得到 catalog JSON；签名验证的输入是其**原始字节** |
| `signature` | base64 的 Ed25519 签名（`Curve25519.Signing`，32 字节公钥） |

未知字段被忽略。因此**不要**依赖新增信封字段来增强安全语义：信封里除 `payload` 之外的
内容都不参与签名，真正被签名的只有 payload 字节。算法固定为 Ed25519，不写 `algorithm`
字段（客户端不读取，写了也不构成约束）。

验签失败、JSON 损坏、`schemaVersion` 未知、`keyID` 不匹配、payload 不是合法 catalog：
一律拒绝，且不会退化到未签名数据。

## 3. Catalog（`schemaVersion: 1`）

生产流程只生成**单版本** catalog：`runtimeVersion` + 恰好两个 `releases`
（`darwin-arm64`、`darwin-x64`）。

| 字段 | 必填 | 客户端用途 |
| --- | --- | --- |
| `schemaVersion` | 是 | 必须等于 1 |
| `runtimeVersion` | 是 | 版本身份 = Harness 版本；必须通过安全字符校验 |
| `releases[]` | 是 | 每个架构恰好一条 |
| `releases[].architecture` | 是 | 与本机架构匹配（`darwin-arm64` / `darwin-x64`） |
| `releases[].platform` | 否 | `macos`；客户端忽略（按 `architecture` 判断） |
| `releases[].runtimeVersion` | 是 | 必须等于 catalog 的 `runtimeVersion` |
| `releases[].nodeVersion` / `harnessVersion` / `pnpmVersion` | 是 | 非空；与 manifest 逐字段比对 |
| `releases[].nodeArchiveSHA256` | 是 | 64 位十六进制 |
| `releases[].harnessPackageIntegrity` / `pnpmPackageIntegrity` | 是 | 非空 npm integrity |
| `releases[].dependencyLockSHA256` | 否 | 审计用，客户端忽略 |
| `releases[].dataFormat` | **事实上必填** | `{id, compatibleWith[], migration}`；缺失会被当成 unknown 并阻塞已存在数据的用户更新 |
| `releases[].pluginMarket` | **事实上必填** | `{package, version, integrity, harnessRange}`；客户端据此安装插件市场，缺失时回退到 App 编译内的兜底 pin |
| `releases[].artifact.runtimeVersion` / `architecture` | 是 | 必须与 release 一致 |
| `releases[].artifact.url` | 是 | 必须等于第 1 节的固定形状 |
| `releases[].artifact.sha256` | 是 | 64 位十六进制；下载后逐字节校验 |
| `releases[].artifact.size` | 否 | 审计/运维用，客户端忽略 |

未知字段被忽略（Swift `Codable` 合成实现），所以**新增字段是兼容的**，删除或改变已有
字段语义不兼容。`schemaVersion` 不能在不破坏旧客户端的前提下改变含义：客户端遇到未知的
`schemaVersion` 会整体拒绝。

### Plugin market pin

`pluginMarket` 和 `dataFormat` 一样，是「发布管线必须做出决定」的字段——决定权在构建
Runtime 的人手里，因为只有它同时知道 Harness 版本和市场的兼容声明：

- 客户端用 `package@version` 在 profile 里安装市场（`pnpm add <package>@<version>
  --save-exact`），并要求 `pnpm-lock.yaml` 里出现同一个版本与 `integrity`；
- `harnessRange` 抄自市场包自己的 `peerDependencies`（按 `@deepseek-ai/dsh-settings`、
  其次 `@deepseek-ai/dsh` 的顺序读取，两者共享同一个版本号）；
- 兼容性由客户端按 `PluginCompatibility` 的语义判断：在范围内才允许安装，不在范围内就以
  「需要 X，当前为 Y」明确报错，范围读不懂时按兼容处理而不是拒绝；
- 解析顺序是「已安装 Runtime 的 manifest → catalog release（仅当它描述的正是同一版本，
  或尚未安装）→ App 编译内的兜底 pin」。因此 `pluginMarket: null` 是合法值：客户端会退回
  兜底 pin，并在不兼容时报出范围，而不是「装上了但界面崩」。

发布侧对应实现：`Scripts/resolve-plugin-market.js`（按同样的语义挑选最新兼容版本）、
`build-runtime.sh`（写入 manifest 与 metadata）、`generate-runtime-catalog.sh`（要求这个
决定存在并带进 catalog）、`runtime-smoke.sh`（在 scratch profile 里按 pin 实装一次并让
Harness 带着它启动）。

安装市场时**禁用 install / lifecycle script**（`npm_config_ignore_scripts=true`）：市场是
已构建好的 tarball，安装它不该执行任何包内脚本。这是客户端策略而不是 smoke 测试的临时
限制，`runtime-smoke.sh` 用同样的策略安装，所以它验证的就是用户真实得到的行为。Runtime
自身的依赖闭包同样整体禁用脚本，需要构建的包（`fs-ext`）由 `build-runtime.sh` 显式处理，
并且由 `Scripts/audit-dependencies.js` 保证不会有新的包悄悄漏进来。

## 4. Artifact 布局与 manifest（`schemaVersion: 3`）

archive（gzip 的 tar）根目录只允许：

```text
manifest.json
node/<architecture>/bin/node                     # 可执行；--version 必须等于 manifest.nodeVersion
harness/<architecture>/<harnessVersion>/node_modules/@deepseek-ai/dsh/lib/bin.js
harness/<architecture>/<harnessVersion>/node_modules/.bin/pnpm            # 可执行
harness/<architecture>/<harnessVersion>/node_modules/pnpm/package.json    # version == manifest.pnpmVersion
harness/<architecture>/<harnessVersion>/node_modules/node-pty/prebuilds/<architecture>/pty.node
harness/<architecture>/<harnessVersion>/node_modules/node-pty/prebuilds/<architecture>/spawn-helper  # 可执行
```

任何其它根级条目（包括 macOS 的 `.DS_Store`、AppleDouble `._*`）都会让客户端以
“包含未授权文件”拒绝整个 artifact——这也是打包时会显式排除它们的原因。

`manifest.json` 的字段必须与 catalog 中对应 release 完全一致：
`schemaVersion`（3）、`runtimeVersion`、`architecture`、`nodeVersion`、`harnessVersion`、
`pnpmVersion`、`nodeSHA256`、`harnessPackageIntegrity`、`pnpmPackageIntegrity`、
`dataFormat`。多出来的字段（`platform`、`dependencyLockSHA256`、`provenance`）被忽略，可以
安全新增。

`pluginMarket` 也写在 manifest 里，让离线安装自带自己的市场 pin；但它**不参与版本一致性
比较**——它描述的是配套包，不是这份安装的字节，所以同一份 Runtime 换个市场版本仍然算
同一个安装。

artifact 的字节身份（`artifact.sha256` / `size` / `url`）**不在** archive 内的
`manifest.json` 里：manifest 是 archive 自身的一部分，把它自己的摘要写进去是循环定义。
字节身份由构建后产出的 `artifact-<version>-<arch>.json` 和签名 catalog 的
`releases[].artifact` 表达，客户端先按 SHA-256 校验下载到的字节，再校验 archive 内的
manifest 字段与 catalog release 一致。三个层级因此落在：

| 层级 | 记录位置 |
| --- | --- |
| `runtimeVersion`（= `harnessVersion`）/ `platform` / `architecture` | archive 内 `manifest.json`、`artifact-*.json`、catalog |
| `artifact.sha256` / `size` / `url` | `artifact-*.json`、签名 catalog（客户端下载与校验的唯一依据） |

## 5. 版本比较语义

`check-catalog-precedent.sh` 复刻了客户端 `RuntimeVersionOrdering` 的语义，发布端与客户端
必须一致：

- 版本按 semver 解析比较，不做字符串比较：core 先比（`0.2.0 < 0.2.1`），同一 core 下预发布
  低于正式版（`0.2.0-rc.10 < 0.2.0`），预发布标识符先按数值再按字典序
  （`0.2.0-rc.9 < 0.2.0-rc.10`）；
- 历史形式 `<harness>-ver<N>` 仍可解析：同一个 Harness 版本下它大于纯版本号，更新的 Harness
  版本则大于旧 Harness 的任何 `<harness>-ver<N>`；
- 无法识别的字符串排在可识别的 Runtime 版本之后，其它情况退化为逐段比较。

## 6. 安装、健康检查与回滚（发布端不要破坏的语义）

- 安装到 `Runtimes/<runtimeVersion>`，不覆盖正在运行的 Runtime；同一版本但内容与 manifest 记录
  不一致时，客户端会拒绝覆盖已有安装（开发阶段重装即可）。发布端重新打包时替换的是 release
  附件与 catalog 里的 `sha256`。
- 启动后做健康检查（`settings/describe`；启动超时 90s、请求超时 5s）；失败则自动回滚到
  上一个 known-good Runtime，回滚完全离线。
- 数据格式：`dataFormat.id` 相同或在 `compatibleWith` 中 → 复用数据；不兼容 → 新建隔离
  profile，**不迁移、不覆盖、不删除**旧数据；未声明 `dataFormat` → 阻塞更新。
  `migration` 目前只是标记，客户端不会自动执行迁移。
- 进程生命周期：Harness 运行期间可能 fork 出自身（观察到的形态是命令行完全相同的另一个
  `dsh web` 进程，取决于启动环境）。因此「只对启动时拿到的那个 PID 发 SIGTERM」不保证整棵树
  退出——被 SIGTERM 的父进程退出后，子进程会被 reparent 到 launchd 并继续存活。客户端停止
  Runtime 时必须按进程组停止（或按启动时记录的 descendants 清理）。`runtime-smoke.sh` 会在
  SIGTERM 之后断言「启动期间观察到的 descendants 全部退出」，并在自己的 EXIT 清理里做兜底：
  只对本次观察到过的 PID 依次 TERM → 短暂 grace → KILL，best-effort，绝不按名字或模式杀进程
  （共享实现见 `Scripts/lib/process-tree.sh`，真实进程场景见
  `Scripts/tests/process-tree-scenarios.sh`）。
- 完整性判断：不要用「目录存在」判断 Runtime 是否可用。安装是否完整只能由 manifest 与签名
  catalog 的比对结果决定（目录只有在 `manifest.json` 可解析、且字段与 catalog 记录一致时才可用）；
  发布端保证 archive 内 manifest 与 catalog 一一对应，catalog 的 `sha256` 是唯一身份来源。
- 已安装构建的身份：`runtimeVersion` 不是 artifact 身份（同版本 repack 会发布不同字节，见
  第 0 节）。客户端判断「已装了哪个构建」至少需要 `(runtimeVersion, architecture, artifact
  sha256)` 三者；只用版本号会把两个不同构建当成同一个。

## 7. 变更规则

| 变更 | 是否兼容 |
| --- | --- |
| catalog / manifest / metadata 新增字段 | 兼容（客户端忽略未知字段） |
| 新增 `releases[]` 条目（更多架构） | 客户端要求每个架构恰好一条，多架构需要改客户端 |
| 删除或改语义地修改已有字段 | 不兼容 |
| 改 release tag / 附件名 / URL 形状 | 不兼容 |
| 改 manifest `schemaVersion` | 不兼容（客户端只接受 3） |
| 改 `architecture` 的取值格式 | 不兼容 |
| 改信封字段名或签名算法 | 不兼容（需要同时更新 App 与签名流程） |

## 8. Harness 安全姿态（随 Runtime 发布，客户端要遵守）

Runtime 打包的 Harness 自带两层安全能力，随 artifact 一起发布，不需要客户端额外配置：

- **文件效果沙箱**：子进程按策略运行，模式取自 `@deepseek-ai/dsh-sandbox-policy` 导出的
  `SANDBOX_MODES` —— `read-only`（fail-safe 默认）、`workspace-write`（仅会话工作区）、
  `danger-full-access`。macOS 走 `sandbox-exec`（Seatbelt）套用生成的 profile；Linux 走
  bwrap → Landlock；Windows 走 ACL 受限令牌（后两者与我们发布的 darwin artifact 无关）。
- **凭据引用**：配置里只写凭据名，值存在 `$DSH_HOME/.env`（文件 `0600`、目录 `0700`、原子写入），
  该次运行的进程环境变量优先；不依赖 macOS Keychain，因此无 GUI / headless 环境同样可用。

**fail closed 是硬语义**：Harness 在第一次真正需要 confinement 时函数式探测 runner（用真实的
`read-only` profile 执行一次 `sandbox-exec … -- true`）并缓存结果；探测失败时抛
`SandboxUnavailableError`，**不会**退化成不加限制地执行原命令。被拒绝的受限调用可以经用户批准的
一次性 escalation 重试。

客户端由此承担的义务：

- 不要让它运行在无法套用 Seatbelt profile 的环境里（例如把 Runtime 放进 App Sandbox）；当前
  DSH Studio 没有 App Sandbox 权利，这一点是满足的。
- 把「sandbox unavailable」当成明确错误呈现给用户，不要静默继续，也不要替用户放宽模式。
- 一次性 escalation 必须由用户本人批准。

发布侧验证：`runtime-smoke.sh` 断言这些包随 artifact 存在、能被打包的 Node 加载、模式列表未被
改名，并且 **koffi**（Harness 唯一的原生运行时依赖，上游按精确版本 pin）的已安装版本与 pin 一致。
它**不**执行真实的受限命令（那需要 session 与模型），也**不**验证客户端机器上的 Seatbelt 可用性
——后者只能由客户端在真实运行环境里判定。
