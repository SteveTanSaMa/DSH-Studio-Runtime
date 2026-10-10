# 数据兼容性契约（草案，跨仓库）

> **状态：草案。** 本文件不改变任何生产语义：`docs/runtime-contract.md` 与线上 catalog 里的
> `dataFormat` 仍然按现状工作，直到 App 侧具备消费下述语义的能力、并且两边同时切换。
> 本阶段只提交证据、设计、测试矩阵与迁移顺序。

## 1. 现状与问题

- 我们发布的 catalog/manifest 声明：`dataFormat: { id: "sqlite-v2", compatibleWith: [], migration: null }`。
- 实际数据（本机实测，0.2.1-alpha.2 运行中）：
  - `$DSH_HOME/sessions/…/session.v4.jsonl.zstd`（**没有** `.db`）；
  - `$DSH_HOME/storages/session_projcache/…`、`storages/workspace.json` 等 JSON；
  - 安装树内 `@deepseek-ai/dsh-session-format-catalog` 声明 `currentVersion: 4`。
- 文档早已承认这一点，却仍断言标签"正确"（`docs/historical-versions.md:36-47`）——属于自相矛盾。
- 结论：`sqlite-v2` **既不描述写入格式，也从不触发任何隔离**；真正需要它起作用的那天它会失效。

## 2. 官方权威事实（逐条带出处）

| 问题 | 权威事实 | 出处 |
| --- | --- | --- |
| 权威写入口 | `SESSION_FORMAT_VERSION = 4`，且被注明是"代码里唯一手工维护的当前写入版本号" | `packages/core/session/src/types.ts:67-89` |
| 机器可读目录 | `session-format-catalog` 导出 `currentVersion: 4` 与 codec v0…v4、迁移边 v0→v1…v3→v4 | `packages/session/session-format-catalog/src/generated.ts:17-31` |
| 发布记录 | `latestFinalizedVersion: 4`；`latestReleasedVersion: 3`（`evidenceTag: dsh-v0.1.5-alpha.1`） | `docs/session-format-status.md`（YAML 记录块） |
| 唯一持久化 provider | `session-persistence-jsonl` 是"sole first-party Session-persistence provider"；默认 zstd；写入当前代际，**永不移动/替换/删除已提交的代际** | `packages/session/session-persistence-jsonl/README.md:32,48,82` |
| 读旧数据 | 相邻迁移链在**内存**中跑完得到当前逻辑值；写回时才发布当前代际 | `.agents/notes/implemented/architecture/2026-08-10-session-log-version-mechanism.md:17` |
| 读新数据 | 明确拒绝：`stored Session uses newer format v${stored}; this build writes v${current}` | `packages/session/session-format/src/catalog.ts:52-58`、`chain.ts:81-84` |
| 一次性数据切断 | SQLite provider 已被移除："Existing databases written by the removed provider are not opened or migrated" | `.agents/notes/implemented/simplification/2026-08-30-jsonl-only-session-persistence.md:17-19` |
| 非 Session 数据 | KV 域各自带版本：`session_projcache` v7、`compatibleVersions [3,4,5,6]`、per-record、不兼容记录"备份并跳过"；`workspace` v2、single 布局、整单元版本不符即拒绝 | `packages/session/session-projection-cache/src/spec.ts:100-107`、`packages/workspace/workspace/src/spec.ts:76-84`、`packages/storage/storage-json/src/format.ts:73-79,102-108` |
| 派生/可丢弃数据 | `session-query-sqlite` v8："Incompatible versions reset in place"（只作 `:memory:` 索引） | `packages/session-query/session-query-sqlite/src/schema.ts:7-8` |

**机器可读兼容信息是存在的**：`@deepseek-ai/dsh-session-format-catalog` 随我们打包的树一起发布，
构建期即可 `import` 它的 `currentVersion`（我已在本机安装树里验证该包存在且可加载）。

## 3. 四个"格式"必须分开

| 维度 | 含义 | 当前实际值 |
| --- | --- | --- |
| 能读 | 本代际 + 迁移链上所有更旧代际 | v0…v4 |
| 会写 | 只写当前代际（不改写旧文件） | v4 |
| Profile 里实际存在 | 每个 session 目录可能有多个 `session.vN.jsonl.zstd`；storages 各有域版本 | 实测 v4；storages 见上表 |
| 不可逆 | 不存在"就地改写"的迁移；唯一不可逆是 SQLite provider 被移除（旧 .db 既不读也不迁） | — |

## 4. 契约草案

### 4.1 Runtime 发布时声明什么

- **不新增字段、不立即改语义。** 未来切换时，`dataFormat.id` 由构建期从产物派生（读
  `session-format-catalog` 的 `currentVersion`），形如 `session-v4`；`compatibleWith` 列出该构建
  仍可读的**更旧代际**（由迁移链决定，例如 `session-v0`…`session-v3`）。
- `migration` 保持 `null`：**本仓库不执行迁移**（迁移是 Harness 自己的行为，客户端不参与）。
- 若将来非 Session 数据的版本也会导致不兼容，再评估是否需要第二维度；**本阶段不建议扩 schema**。

### 4.2 App 应该持久化什么

- 写入者的声明（当时的 `dataFormat.id`）——已有 `profile.json.dataFormatID`；
- **用户数据实际达到的代际**：即"扫描得到的最大值"，而不是声明值（两者会分叉，见 4.3）；
- 活跃/上一版本记录——已有 `active-state.json`。

### 4.3 App 应该从 Profile 检查什么（可实现的检查）

1. `sessions/**/session.vN.jsonl.zstd`（或 `session.jsonl.zstd` = v0）：取 `max(N)` 作为**数据代际**；
2. `storages/**/*.json` 内记录的域 `version` 字段：取各域最大值并与构建能读的域版本比较；
3. 是否存在 `*.db`（已被移除的 SQLite provider 的数据）：存在即视为"旧格式遗留"，不参与复用判断，
   只在诊断里提示。

> 要点：**声明的代际不足以判断**。v5 运行后再回滚到 v4 时，profile 里记录的仍是 `session-v4`，
> 但磁盘上是 v5 文件——只有扫描才能发现。

### 4.4 决策规则

| 场景 | 规则 |
| --- | --- |
| 允许升级 | 新 Runtime 的代际 ≥ 数据代际，且数据代际 ∈ 新 Runtime 的 `compatibleWith`（或其自身代际） |
| 允许回滚 | 目标 Runtime 的代际 ≥ **数据代际**（即它能读）；否则不得回滚 |
| 必须拒绝回滚 | 目标 Runtime 的代际 < 数据代际（旧构建会拒绝打开新数据） |
| 需要数据隔离 | 用户明确选择；或前向移动时数据代际不在 `compatibleWith` 内且用户接受"从空 profile 开始" |
| 未知/缺失声明 | **fail closed**：若 profile 非空则不启动、不复用、不回滚；提示升级或让用户显式选择隔离 |

## 5. 场景测试矩阵（App 侧为主，Runtime 侧提供断言点）

| # | 场景 | 期望行为 | 谁来验证 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | v4 Runtime → v4 Runtime | 复用 profile，无隔离、无提示 | App | 未验证（当前靠手写 id 比较） |
| 2 | v4 Runtime → v5 Runtime | 升级允许，复用 profile，v4 文件被内存迁移读取 | App + Harness | 未验证 |
| 3 | v5 Runtime → v4 Runtime（回滚） | **拒绝回滚**，保持 v5 活跃 | App | 未验证 |
| 4 | Profile 已产生 v5 数据 | 任何 v4 目标都不得激活；除非用户显式选择隔离 | App | 未验证 |
| 5 | 新 Runtime 安装成功但健康检查失败 | 回滚到旧 Runtime；**若旧 Runtime 读不了数据则不得回滚**，保持失败态并明确报错 | App | 已有回滚机制，跨代际规则未实现 |
| 6 | 旧 Runtime 可启动但读不了新数据 | Harness 抛 `SessionFormatUnsupportedError` 并指明方向；App 应把它呈现为"需要更新的 Runtime"，不是"数据损坏" | Harness 已实现，App 呈现待定 | 部分已实现 |
| 7 | 数据格式信息缺失/未知 | fail closed：不复用、不回滚，提示用户 | App | 部分已实现（`.dataCompatibilityUnknown`） |

Runtime 侧可加的断言（构建期，不需要 App）：catalog 声明的代际必须等于产物内
`session-format-catalog.currentVersion`；smoke 断言该包存在且可加载（与现有 seam 检查同一模式）。

## 6. 迁移顺序（跨仓库）

1. **App 先具备能力**：扫描 profile 数据代际、记录它、按 4.4 决策；此时仍消费旧的 `sqlite-v2`（行为不变）。
2. **双写/兼容期**：Runtime 的声明改为派生值（`session-v4`），App 同时理解两种 id（旧 id 视为"未知但已知历史"→ 映射到 v4）。
3. **切换**：App 只认新语义；`docs/runtime-contract.md` 与 README 同步更新。
4. 全过程**不触碰用户数据**：不迁移、不删除、不就地改写。

## 7. 尚未验证 / 需要确认

- 上游 `latestReleasedVersion` 记录（3）与实际 alpha 线写入（4）的差异属于上游记账，未向upstream确认；
- 扫描 profile 的实现细节（session 目录结构、加密/压缩后缀、域文件位置）需要在 App 侧按真实布局落地；
- "回滚被拒绝"的用户体验（提示文案、可否选择隔离）需要 App 侧产品决定。
