# 同版本重新打包（repack）：定位与验收规则

> 本文定义**例外恢复机制**的边界，不是日常更新策略。日常更新 = 上游发布新的 Harness 版本 →
> 我们发布新的 `runtimeVersion`。只有在第 2 节列出的理由下，才允许对**已发布过的版本**重新打包。

## 1. 身份模型（结论：现有字段已足够，不新增 schema）

期望身份：`(runtimeVersion, architecture, artifact.sha256)`。逐项核对：

| 检查 | 结论 | 证据 |
| --- | --- | --- |
| 1. Catalog 是否已提供全部必要信息 | **是**。线上 payload 每个 release 带 `artifact { runtimeVersion, architecture, url, sha256, size }`，`sha256` 是 64 位 hex 摘要 | 实测线上 catalog（`verify-runtime-catalog.sh` 解出的 payload）；生成逻辑 `build-runtime.sh:399-428` |
| 2. Manifest 是否足以验证安装内容 | **不足以承担身份**。它记录 `nodeSHA256`、两个 package integrity、`dependencyLockSHA256`、`dataFormat`、`pluginMarket`，但**不可能包含自身归档的 sha**（自引用悖论）。因此"这份字节"的身份只能由 **catalog 提供、App 持久化** | `build-runtime.sh:294-359`；客户端比较逻辑（App 侧 `RuntimeInstallationManifest.matches`）不含 artifact 摘要 |
| 3. 重新打包后 SHA 是否一定重算 | **是**。catalog 生成时对**磁盘上的产物字节**重新哈希与量长，与 metadata 不一致即拒绝；重建本身会产生新字节（mtime 等），因此新 sha | `generate-runtime-catalog.sh:130-149` |
| 4. Catalog 与 Artifact 的非原子窗口 | **存在但方向安全**：流水线先逐个上传 artifact，最后上传 catalog。窗口内 = "新字节 + 旧 catalog" → 客户端 sha 校验失败并拒绝安装；**不会**出现"catalog 指向不存在的对象" | `runtime-builder.yml:480-513`（artifact 循环在前，catalog 在后） |
| 5. 旧 Catalog 缓存与新 Artifact 混用 | 发布端无法避免客户端缓存过期；正确处置在 App：**sha 不匹配 ⇒ 绕过缓存重取一次 catalog**，仍不匹配才报错。**不得**用"同版本缓存优先"丢弃更新的远端内容（App 当前实现会丢弃，导致永久失败） | 发布端不缓存；App 侧问题见审计报告 |
| 6. 安装失败后恢复旧构建所需信息 | 全部在本地：旧版本目录 + 其 `manifest.json` + `active-state.json` 的 previous 记录。**不需要重新下载**——catalog 只描述当前版本，历史版本的 sha 无处可取，因此下载旧版本是**不可验证**的，回滚绝不能依赖下载 | App 侧 `RuntimeLocator` / `RuntimeProvisionerUpdates` |
| 7. 旧版 App 与新版 Catalog 兼容性 | 结构兼容：`schemaVersion` 保持 1，只允许附加字段，旧 App 忽略未知字段。**语义不兼容**：若 `dataFormat.id` 语义切换，旧 App 会视为"未知"并按 fail closed 拒绝——所以语义切换必须与 App 发版同步 | `docs/runtime-contract.md` §7 变更规则 |

**建议：不增加 `artifact.buildId`。** `artifact.sha256` 已经是构建身份；缺少的是 App 的持久化，
那是客户端实现问题，不是 schema 缺口。只有出现"必须在 catalog 里表达一个 sha 之外的构建维度"
的具体需求时，才重新评估（本阶段未发现此类需求）。

## 2. 何时允许重新打包（白名单）

允许：

1. **依赖安全修复**：传递依赖被 yank / 披露漏洞，必须重建同一 Harness 版本；
2. **构建基础设施缺陷**：已发布的 artifacts 无法启动、架构错误、缺少原生模块等；
3. **上游撤回**：上游把该版本标记为 yank，我们用同一版本号替换为可用构建。

不允许：为了让内容"更新一点"而重打包（应等新的 Harness 版本）、为了让某个客户端绕过缓存而重打包、
在没有记录原因的情况下重打包。

记录要求：release notes 必须写明**为什么**重打包，并列出新旧 `sha256`（流水线已自动生成 hashes 段落）。

## 3. 为什么版本号不变而 sha 改变

`runtimeVersion == harnessVersion` 是既定规则（一个 Harness 版本 = 一个当前 Runtime），版本号描述的是
**上游 Harness 身份**，不是我们的构建批次。构建批次的身份由 `artifact.sha256` 承担：

- catalog 始终只描述**一个当前版本**（每架构一条 release），所以"同版本两条记录"在结构上不存在；
- repack 是**替换**语义：同一 release、同一 tag、同一附件名，内容与 sha 变化。

## 4. 旧客户端可能出现的行为（必须接受）

| 客户端状态 | 行为 | 评价 |
| --- | --- | --- |
| 已装旧 sha，manifest pins 未变 | 视为"已安装"，**不会**提供更新 | 可接受（pins 未变说明安装内容等价） |
| 已装旧 sha，pins 已变 | 拒绝覆盖已有安装；若该版本被标记为活跃冲突，进入 `.invalid` | **需要 App 侧修复**（当前会僵局） |
| 缓存了旧 catalog | 用旧 sha 校验新字节 → 校验失败 → 永久失败（当前实现） | **需要 App 侧修复**（重取 catalog） |
| 从未安装过该版本 | 正常安装新 sha | 无影响 |

## 5. 发布失败时如何恢复

- 构建/校验阶段失败：**什么都没上传**，线上保持原样。
- 上传中途失败：release 可能处于"一个架构已替换、catalog 未更新"的状态 → 客户端全部 fail closed；
  - 流水线会删除**本次运行创建的** release（自愈）；对已存在的 release 不会自动删除；
  - 恢复方式：重新 dispatch 同一版本（补齐两个架构 + catalog），或按 README §4 手动删除 release 后重建；
  - 不存在"半替换成功但 catalog 已指向新字节"的状态（catalog 最后上传）。
- 结论：repack 失败的最坏结果是"该版本暂时不可安装"，不会破坏已安装的 Runtime 或用户数据。

## 6. 为什么不能假定附件替换是原子操作

GitHub Release 的附件是**逐个上传**的独立对象，没有跨附件事务；CDN 也有各自的缓存与传播时间。
因此：

- 任何"先把 catalog 指向新字节、再慢慢上传"的顺序都是错的（会导致客户端下载 404）；
- 任何依赖"替换瞬间完成"的客户端逻辑都是错的（必须能容忍 sha 不匹配并重取）；
- 发布端的顺序（artifact 先、catalog 后）正是为了让窗口表现为"可检测的不一致"。

## 7. 验收规则（与 App 侧对齐的最低要求）

发布端（本仓库，已实现）：

- 每次 repack 都重新计算 sha/size，并在 catalog 中体现；
- 拒绝降级版本；允许同版本替换（`check-catalog-precedent.sh`）；
- 发布后从公开 URL 回下载验签 + 校验 sha/size 与 URL 形状。

App 侧（待实现，本轮不改）：

- 持久化安装时 catalog 给出的 `artifact.sha256`，作为"这份安装"的身份；
- sha 校验失败时**重取一次 catalog**（绕过缓存）再决定；
- 不再用"同版本缓存优先"覆盖更新的远端内容；
- 拒绝跨代际回滚（见 `docs/data-compatibility-contract.md` §4.4）。

## 8. 本阶段不做

不引入多构建身份体系（例如 `buildId`/多 release 并列）、不做内容寻址存储、不做增量补丁；
不修改 URL/命名/签名格式/`runtimeVersion == harnessVersion` 规则。
