# INTEGRATION — DSH-Studio-Runtime 与其他仓库的关系

> 严格区分：**已验证**（有代码/产物/命令证据）与**待确认**（未验证的推测一律不写成事实）。
> 检查时间：2026-10-11。本文件不建立任何新关系，只记录可核实的事实。

## 1. 与 DSH Studio（客户端）——**已验证，这是本项目存在的理由**

| 维度 | 内容 | 证据 |
| --- | --- | --- |
| 关系类型 | 构建/发布依赖 + 运行时依赖 + 共享协议 | 客户端代码 |
| 取 catalog | 固定 URL `…/releases/download/runtime-catalog/runtime-catalog.signed.json` | `RuntimeCatalogService.swift:50-52` |
| 验签 | 内置公钥（`Info.plist` → `RuntimeCatalogTrust`），keyID `runtime-catalog-v1` | `Info.plist:31`、`RuntimeCatalogTrust.swift:12-32` |
| 产物 URL | 由 catalog 的 `runtimeVersion` **逐字符构造**（形状被写死） | `RuntimeReleaseCatalog.swift:126-145` |
| 字节校验 | 下载后校验 SHA-256 == catalog 的 `artifact.sha256` | `RuntimeProvisionerArtifactInstallation.swift:161-167` |
| 安装 | staging `.Runtime-<uuid>` → 校验 manifest 与 catalog 一致 → 启动 → 健康检查 → 写 `active-state.json` | 同上 `:26-99`；`RuntimeManager+Health.swift:47-52` |
| 回滚 | 保留上一版目录，失败自动回滚（数据目录永不被移动/改写） | `RuntimeProvisionerUpdates.swift`、`RuntimeDataProfileStore+Activation.swift:70` |
| 版本比较 | `RuntimeVersionOrdering`（SemVer + prerelease 规则） | 客户端测试 |
| 数据格式 | 读 catalog/manifest 的 `dataFormat`，不兼容则新建隔离 profile | `RuntimeDataCompatibility.swift:15-79` |

**契约冻结面**（改动即破坏已发布客户端）见 `ARCHITECTURE.md §5`。
**契约权威文档**：`docs/runtime-contract.md`。

### 1.1 需要在统一工作区里协调的客户端缺口（只读审计发现，本仓库无法单方面修复）

1. **不持久化 `artifact.sha256`** → 无法区分同版本不同字节（契约要求 `(runtimeVersion, architecture, sha256)`）。
2. **同版本 repack 时缓存优先** → 保留旧 catalog、丢弃新内容 → 校验永久失败（需手删缓存）。
3. **staging 目录无启动清理** → 崩溃残留 `.Runtime-<uuid>`（本机实测存在）。
4. **`.invalid` 僵局** → 同版本内容冲突时既不更新也不启动。
5. **数据代际检查缺失** → 回滚跨代际时客户端无法预判（旧 Runtime 会拒绝打开新数据）。

这 5 条的修复都在客户端；本仓库**在它们完成前不切换任何公开字段语义**。

## 2. 与官方 DeepSeek Harness——**已验证的外部依赖**

| 维度 | 内容 |
| --- | --- |
| 依赖形式 | npm 包 `@deepseek-ai/dsh@<精确版本>`（+ 传递依赖闭包） |
| 版本发现 | GitHub Releases API（`deepseek-ai/deepseek-harness`，tag `dsh-v*`） |
| 契约面 | 启动参数 `web --host 127.0.0.1 --port 0 --no-open`、就绪行 `dsh web: http://…`、RPC `settings/describe` |
| 数据格式 | 上游 `SESSION_FORMAT_VERSION`（当前 4）+ 迁移链 + 明确拒绝读新格式 |
| 插件 | profile 内的 `pnpm`（`dsh plugin …`）；**上游没有官方市场** |
| 本仓库不做 | 不 fork、不 patch、不重写 Harness |

**风险**：上游协议或插件机制变化会打断 smoke（fail closed，需同步更新 `Scripts/runtime-smoke.sh`）；
历史上已发生过一次。

## 3. 与 MiPlay、DXMT、LSFG——**大部分待确认**

| 仓库 | 核实到的事实 | 结论 |
| --- | --- | --- |
| MiPlay | 存在于 `/Users/stevetan/SteveTan/Document/Xcode/MiPlay`，是 git 仓库（`github.com:SteveTanSaMa/MiPlay.git`），Xcode 工程（`MiPlay.xcodeproj`、`MiPlayTests`、QA/性能目录） | **与本项目无已证实关系**：本仓库 grep 无任何 MiPlay 引用；MiPlay 的文本文件里也没有 DSH Studio 引用。**待确认**是否需要工程级协调。 |
| DXMT | 在 `Xcode/`、`Xcode/MiPlay` 下**均未找到** | **待确认**：本地不可见，无法判断关系。 |
| LSFG | 同上，**未找到** | **待确认**。 |
| AnimeGameWineReleaseFetcher | 本地存在（`Xcode/` 下），未做进一步检查 | **待确认**。 |

**不做推断**：不假定 DXMT/LSFG 与 MiPlay 或与本项目存在依赖关系——没有任何证据支持。

## 4. 与本仓库共享的"资源"清单（迁移时要一起带走）

| 资源 | 位置 | 说明 |
| --- | --- | --- |
| 公开信任锚 | `keys/runtime-catalog-public.txt`（仓库）+ 客户端 Info.plist | 两处必须描述同一对密钥 |
| 签名私钥 | GitHub Actions environment `runtime-signing` 的 secret | **不随仓库迁移**；丢失/泄露都需发新版 App |
| 仓库变量 | `RUNTIME_PNPM_VERSION`（必需）、`RUNTIME_DATA_FORMAT_ID`、`RUNTIME_DATA_FORMAT_COMPATIBLE_WITH`、`RUNTIME_PLUGIN_MARKET_VERSION`（可选） | 缺失会 fail closed |
| 发布产物 | GitHub Releases（`runtime-<v>` + `runtime-catalog`） | 已发布产物**不可变**，迁移不得重建或删除 |
| 分发 URL | `releases/download/runtime-catalog/…` | 被客户端写死 |

## 5. 跨仓库改动风险清单（统一工作区里优先对齐）

1. **字段语义切换**（`dataFormat`）必须 App 先能消费 → 双写 → 再切换（见 `docs/data-compatibility-contract.md`）。
2. **产物身份**（`artifact.sha256`）需要客户端持久化，属客户端改动；本仓库已提供全部必要字段。
3. **回滚跨代际**规则需两侧一致（客户端决定是否允许回滚；发布端只声明代际）。
4. **插件市场解析职责**若迁移，需要客户端接受"安装期解析"带来的 registry 动态性。
5. **签名锚轮换**必须与 App 发版同步，无法在 Runtime 仓库单独完成。

## 6. 信息缺口（如实记录）

- 无法访问 DXMT/LSFG 的代码或远程仓库；无法判断它们与本项目是否有工程级关系。
- 无法访问客户端仓库的未提交改动（只读审计基于当时工作区）。
- 无法读取 GitHub Secret 内容（`gh` 只能列出名称与时间），因此无法确认私钥备份状态。
