# MIGRATION REPORT — DSH-Studio-Runtime

> 迁移准备报告。生成时间 **2026-10-12**（本地），基于提交 `7451b68`（`main`，与 origin 同步）。
> 本报告只描述**实际执行过的操作**与**可核实的证据**；未验证事项一律标注。

## A. 项目基本信息

| 项 | 值 |
| --- | --- |
| 项目名称 | DSH-Studio-Runtime（本地目录 `DSH Studio Runtime`） |
| 所属工程 | DSH Studio 工程（Swift 客户端 + 本 Runtime 分发） |
| 仓库 | `git@github.com:SteveTanSaMa/DSH-Studio-Runtime.git` |
| 分支 / 提交 | `main` / `7451b68`（冻结前最后一次提交，已推送，无未推送提交） |
| 代码规模 | 28 个受版本控制文件，约 5,965 行 |
| 最新发布 | `0.2.1-alpha.2`（catalog 已验签，双架构 sha256 与线上一致） |
| 迁移文档 | `docs/migration/`（本报告 + 5 份文档） |

## B. 开发冻结状态

- **冻结时没有进行中的开发工作**：工作区干净、无未提交修改、无未推送提交。上一项工作（Phase C 修复）
  在冻结前已完整提交并验证。
- **冻结前三个阶段**（全部完成）：
  - Phase A：审计 + 契约/风险核实（私钥 Runbook、artifact 身份核对、repack 规则、数据兼容草案）
  - Phase B：死代码清理（fs-ext）+ 签名工具 DER 支持 + 回归测试
  - Phase C：cron 版本选择重构 + 跳过列表 + **接线缺陷修复**（`prepare` 缺 checkout、失败被静默）
- **未完成部分**：没有"做了一半"的改动。所有未实施项都是**已设计、明确等待指令**的（数据兼容切换、
  插件市场职责收敛、信任锚轮换能力），已记录在 `DEVELOPMENT_STATUS.md §4`。
- **恢复建议**：从 `HANDOVER.md §7` 的只读核验开始，然后按 §8 的顺序推进。

## C. 文档整理结果

**新增（`docs/migration/`）**

| 文件 | 用途 |
| --- | --- |
| `PROJECT_OVERVIEW.md` | 项目定位、职责、技术栈、目录、当前状态（给零上下文读者） |
| `ARCHITECTURE.md` | 模块与职责、数据结构、数据流、对外接口、运行环境、Mermaid 全景图 |
| `DEVELOPMENT_STATUS.md` | 已完成/已实现未验证/未开始/已知问题/技术债/待验证 |
| `DECISIONS.md` | 12 项重要技术决策（选择、原因、替代方案、限制、调整空间） |
| `INTEGRATION.md` | 与 DSH Studio、官方 Harness、MiPlay/DXMT/LSFG 的关系（区分已证实与待确认） |
| `HANDOVER.md` | 交接文档：10 个必答问题 +「新工作区接管建议」 |
| `MIGRATION_REPORT.md` | 本文件 |

**更新（既有文档，不覆盖历史内容）**

| 文件 | 更新内容 |
| --- | --- |
| `docs/cron-skip-list-design.md` | §9 第 1 项由「未验证」改为「已于 2026-10-12 生产验证」，附三次 run 与结论 |
| `docs/migration/DEVELOPMENT_STATUS.md` | 同步上述证据；记录时间标注 2026-10-11、更新于 2026-10-12 |

## D. 工作区清理结果

**已删除**（4 个文件，全部为 Finder 元数据，`.gitignore` 已忽略，可随时由 Finder 重建）：

| 文件 | 理由 | 是否可重建 | 是否被引用 |
| --- | --- | --- | --- |
| `.DS_Store` | macOS Finder 元数据，非项目内容 | 是（Finder 自动重建） | 否；仅作为"打包时必须排除"的对象出现在构建脚本与文档里 |
| `Scripts/.DS_Store` | 同上 | 是 | 否 |
| `.github/.DS_Store` | 同上 | 是 | 否 |
| `.commandcode/.DS_Store` | 同上 | 是 | 否 |

删除操作使用**显式路径**逐条执行（未使用任何递归/通配删除），执行前后均用
`find … -name .DS_Store` 核对，`git status` 未受影响。

**已保留（有意保留，非"未理解用途"）**

| 内容 | 保留理由 |
| --- | --- |
| `.commandcode/`（48K，含 `taste/taste.md`） | 开发工具的本地工程状态，被 `.gitignore` 忽略，可能与后续工作区上下文有关；不属于垃圾 |
| `keys/runtime-catalog-public.txt` | 客户端信任锚，公开且必须与 App 内的一致 |
| 所有已发布产物、tag、catalog | 不可变发布记录，禁止重建或删除 |

**无需人工确认的清理项**：0（其余目录未发现临时文件、构建产物、缓存、日志；仓库内没有
`node_modules`、`dist`、`*.tar.gz`、`*.signed.json` 等可重建产物——构建全部发生在 CI 的临时目录）。

## E. 当前项目健康状态

| 维度 | 状态 | 证据 |
| --- | --- | --- |
| 离线测试 | **113/113 通过** | 本次迁移核验时重新执行（本地 macOS / bash 3.2） |
| CI | **success** | 最近一次 push 触发的 `verify.yml`（含 113 项） |
| 发布流水线 | **正常** | 修复后三次 schedule run 均成功，选择器输出 `nothing to build`，未发布任何版本 |
| 线上 catalog | **有效** | 本次重新下载并验签：`0.2.1-alpha.2`，双架构 sha256 与记录一致 |
| 已发布产物 | **未变** | `0.2.0-rc.1` / `rc.2` / `0.2.1-alpha.1` / `0.2.1-alpha.2` 保持原样，本次未改动 |
| 依赖与配置 | 完整 | 仓库变量与 environment `runtime-signing` 未改动；私钥未触碰 |
| 已知问题 | 见 `DEVELOPMENT_STATUS.md §4` | 其中 P0 为私钥备份未确认 |
| 未提交修改 | **无** | `git status --short` 仅显示新增的 `docs/migration/` |

**无法执行的验证**（如实说明）：

- **完整构建**：需要网络 + macOS，且会真实产生新产物 → 未执行（也不应在冻结期间执行）。
- **发布后全量校验**（`verify-published-runtime.sh`）：需下载约 400 MB 的两个架构产物 → 未重复执行；
  该检查在每个版本的发布流程中都会自动跑，本次只做了 catalog 验签。
- **真实 Intel 硬件**：无设备。

## F. 跨项目协作事项（迁移后需统一协调）

1. **客户端 5 个缺口**（`INTEGRATION.md §1.1`）：artifact 身份未持久化、同版本 repack 缓存优先导致永久
   失败、staging 无清理、`.invalid` 僵局、跨代际回滚未判定。全部属客户端改动；本仓库已提供所需字段。
2. **数据兼容字段切换**：必须 App 先能消费 → 双写 → 切换；本仓库在切换前**冻结字段语义**。
3. **插件市场解析职责**：是否从 Runtime 移到 App，需要评估 registry 动态解析带来的不确定性。
4. **签名信任锚轮换**：必须与 App 发版同步，无法在 Runtime 仓库单独完成。
5. **MiPlay / DXMT / LSFG**：与本项目**没有已证实的关系**（本仓库无引用；MiPlay 无 DSH 引用；
   DXMT/LSFG 本地未找到）→ 迁移时按「待确认」处理，不要假设存在依赖。
6. **共享资源清单**（锚、私钥、仓库变量、发布产物、分发 URL）见 `INTEGRATION.md §4`。

## G. 迁移就绪程度：**PARTIALLY_READY**

**已具备**：文档齐全且与实际状态一致（含 Mermaid 架构图与决策依据）；仓库干净、无未提交/未推送内容；
测试全绿；发布面稳定且不可变；跨仓库关系已区分「已证实 / 待确认」；清理只动了 4 个可重建的元数据文件。

**仍需处理**（因此不是 READY）：

1. **P0 未解决**：签名私钥的离线备份未确认（只能由仓库所有者完成；丢失/泄露都需发新版 App）。
   Runbook 与恢复步骤已就绪并用临时密钥演练过，但**演练 ≠ 备份完成**。
2. **客户端缺口未修**：5 项，属跨仓库协作事项，本仓库无法单方面关闭。
3. **数据兼容语义尚未切换**：属已设计未实施，需要两侧共同确定迁移顺序。

**不构成阻碍**：以上三项都不影响"把仓库交给新的工程工作区继续维护"；它们是需要在新工作区里继续推进的
已知任务，而不是迁移的技术障碍。

## H. 新工作区接管指引

1. **先读**：`docs/migration/HANDOVER.md`（必读）→ `PROJECT_OVERVIEW.md` → `ARCHITECTURE.md` →
   `DECISIONS.md` → `DEVELOPMENT_STATUS.md`；需要契约细节时读 `docs/runtime-contract.md`，
   需要私钥流程时读 `docs/key-custody-runbook.md`。
2. **先做只读核验**（`HANDOVER.md §7`）：`git status/log` → `run-tests.sh`（期望 113 通过）→
   `gh release list` / `gh run list` 确认发布面未被改动 → 线上 catalog 验签
   （命令见 `HANDOVER.md §7` 第 4 步）。
3. **牢记冻结项**（`HANDOVER.md §5`）：不改版本规则/URL/命名/schema/签名格式/信任锚；不引入 `buildId`；
   不触发发布；不改写历史；不写 secret；提交只署 `SteveTanSaMa`。
4. **第一个合理任务**：如果还没有做，确认下一次 cron 正常（早已验证，见 `DEVELOPMENT_STATUS.md §2`）；
   否则就是与客户端对齐 B3/B4，或推动私钥备份。
5. **跨仓库协作**：按 `INTEGRATION.md §5` 的风险清单推进，任何公开字段语义切换都要两侧同步。
