# HANDOVER — DSH-Studio-Runtime

> **假设读者无法访问任何历史对话**，只能读代码仓库和这份文档。所有状态截至
> **2026-10-11，提交 `7451b68`，`main` 与 origin 同步，工作区干净，开发已冻结**。
> 术语与证据见同目录的 `PROJECT_OVERVIEW.md` / `ARCHITECTURE.md` / `DEVELOPMENT_STATUS.md` /
> `DECISIONS.md` / `INTEGRATION.md`。

## 1. 这个项目是什么？

**把官方 DeepSeek Harness 打包成可验证、可签名、可回滚的 macOS Runtime 产物**，供 Swift 客户端
DSH Studio 下载安装。它只做五件事：构建、验证、签名、发布、发布后验证。它**不** fork Harness、
**不**是客户端、**不**做用户数据策略。

客户端为什么不能自己做：官方没有可复用的独立 Runtime 产物（npm 包不含 Node；桌面 Host 包是 private；
安装包无再分发许可），而 Swift 应用用不了 Electron 的 Node。细节见 `DECISIONS.md` D3。

## 2. 当前开发到了哪里？

**已冻结**。最近三个阶段全部完成并推送：

| 阶段 | 内容 | 结果 |
| --- | --- | --- |
| A | 审计 + 契约/风险核实（私钥 Runbook、artifact 身份核对、repack 规则、数据兼容草案） | 交付 3 份文档；用临时密钥演练了恢复流程 |
| B | 低风险清理（删除死代码 fs-ext 路径、签名工具支持 DER 文件、5 项签名回归测试） | 91→111 项测试通过 |
| C | cron 版本选择重构 + 显式跳过列表 + **接线缺陷修复** | 113 项测试通过，CI 绿 |

**当前发布状态**：已发布 `0.2.0-rc.1`、`0.2.0-rc.2`、`0.2.1-alpha.1`、`0.2.1-alpha.2`（最新）；
`runtime-catalog` 是客户端唯一入口，**已发布产物不可变**。

## 3. 最近在处理什么问题？

1. **Phase C 的接线缺陷（已修，待生产验证）**：`prepare` job 从未 `actions/checkout`，导致新选择脚本
   在 runner 上不存在；更糟的是失败被映射成 `should_build=false`，run 显示 success 却什么都不做
   （**静默停摆**）。修复：加 checkout + 让选择失败 `exit 1` + 两条离线守卫测试（引用路径必须存在、
   读仓库的 job 必须 checkout）。首次真实执行在 2026-10-10T22:36Z **失败**（修复前），**修复后的首次执行
   尚未发生**。
2. **首次真实 cron 的只读检查**：这是当前唯一被授权的验证动作——下一次 schedule run 之后看 prepare 日志，
   预期输出"零候选、不构建"。**若异常：先报告日志与影响，不要自行发布。**
3. 私钥离线备份：**仍未完成**，是唯一的 P0 运维风险。

## 4. 哪些修改尚未完成？

- **没有未提交的修改**（工作区干净）。所有已完成工作都已提交到 `main`。
- **已设计未实施**（且明确要求**不要擅自开始**）：
  1. 数据兼容字段切换（`docs/data-compatibility-contract.md`）；
  2. 插件市场解析职责收敛（`DECISIONS.md` D8）；
  3. 客户端 5 个缺口（`INTEGRATION.md §1.1`）；
  4. 信任锚轮换能力（`DECISIONS.md` D4）。

## 5. 绝对不能遗漏的事项

1. **签名私钥的离线备份未确认**（`docs/key-custody-runbook.md`）。私钥只在 GitHub Actions environment
   `runtime-signing` 里；丢失或泄露都只能"换锚 + 发新版 App"。**临时密钥演练 ≠ 备份完成。**
2. **不要修改已发布的产物、catalog、tag**。它们是不可变的发布记录。
3. **不要在没有明确指令时触发任何发布**（`workflow_dispatch` 会真的开始构建并发布）。
4. **不要改这些冻结项**：`runtimeVersion == harnessVersion`、release URL 形状、附件名、archive 布局、
   `schemaVersion`（manifest 3 / catalog 1 / 信封 1）、签名格式、信任锚、`artifact.sha256` 作为唯一构建身份
   （**不要引入 `buildId`**）。
5. **不要 force-push、不要改写历史、不要 `git reset --hard` / `git clean -fdx`**。
6. **不要把私钥或任何 secret 写进仓库、日志、issue**；`RUNTIME_CATALOG_PRIVATE_KEY_BASE64` 只走环境变量。
7. **提交只署 `SteveTanSaMa`**，不加任何 bot/AI 署名。

## 6. 已经确定的开发约定

- **提交信息**：英文、conventional 前缀（`feat`/`fix`/`chore`/`docs`/`test`）、说明"为什么"、
  不写无信息量的空话。
- **改动前先跑测试**：`./Scripts/run-tests.sh`（113 项，离线、无密钥、不需要 macOS 以外的环境）。
  **CI 必须绿**（`verify.yml` 在 PR 与 main push 上跑）。
- **fail closed 是默认哲学**：拿不准就拒绝并给出可读原因，不做"猜测式降级"。
  **但失败必须可见**（Phase C 的教训：fail closed + 静默 = 停摆没人发现）。
- **脚本兼容 bash 3.2**（macOS 自带），不依赖 bash 4+ 特性（无 `mapfile`、无关联数组）。
- **业务代码改动要成对带上测试**；能离线测的一律离线测，不依赖 registry / GitHub 状态。
- **文档中文为准**，`README.en.md` 是镜像（需人工同步）。
- **发布相关判断以代码为准**，文档是辅助；发现文档与实现不符时，先报告再修。

## 7. 继续开发前应先检查什么

```sh
# 1. 状态与同步
git status --short --branch && git log origin/main..HEAD --oneline   # 期望：干净、无未推送
# 2. 自检
./Scripts/run-tests.sh                                               # 期望：113 passed, 0 failed
# 3. 发布面有没有意外变化（只读）
gh release list --limit 5
gh run list --workflow runtime-builder.yml --limit 5
# 4. 线上 catalog 仍然有效（只读）
gh release download runtime-catalog --pattern runtime-catalog.signed.json --dir /tmp/cat --clobber
./Scripts/verify-runtime-catalog.sh /tmp/cat/runtime-catalog.signed.json \
  "$(sed -n 's/^publicKey=//p' keys/runtime-catalog-public.txt)" /tmp/cat/payload.json
# 5. 若刚过整点：看最近一次 schedule run 的 prepare 日志（Phase C 修复的生产验证）
gh run view <run-id> --log | grep -E "selection:|No unbuilt|should_build"
```

## 8. 下一阶段最合理的工作顺序

1. **只读**确认修复后的 cron 选择逻辑按预期（零候选、不发布）。
2. 推动/等待**客户端 B3/B4**（安装事务 + artifact 身份）落地；在那之前**冻结公开字段语义**。
3. 与客户端协商**数据兼容契约的迁移顺序**（先让它能消费，再切字段）。
4. 推动完成**私钥离线备份**（只能人做）。
5. 只有在上述都稳定后，才考虑插件市场职责收敛等结构性简化。

## 9. 与其他项目协作时需要注意什么

- **DSH Studio**：契约面（§5.4）任何改动都要与客户端同步；客户端有 5 个已确认缺口（`INTEGRATION.md §1.1`）。
- **官方 Harness**：是外部依赖，协议变化会让 smoke 失败（fail closed）；不要 fork。
- **MiPlay / DXMT / LSFG**：**与本项目没有已证实的关系**（本仓库无引用；MiPlay 也无 DSH 引用；
  DXMT/LSFG 本地未找到）→ 迁移时按"待确认"处理，不要假设存在依赖。

## 10. 如何验证本项目可以正常运行

- **离线（推荐，零风险）**：`./Scripts/run-tests.sh` → 113 项通过。
- **真实产物 smoke（有网络，只读产物）**：
  `./Scripts/runtime-smoke.sh "$HOME/Library/Application Support/DSH Studio/Runtimes/0.2.1-alpha.2"`
  → 期望 `Runtime smoke passed: 0.2.1-alpha.2 / Harness … / darwin-arm64`。
- **线上分发面（只读）**：`./Scripts/verify-published-runtime.sh 0.2.1-alpha.2 "$(sed -n 's/^publicKey=//p' keys/runtime-catalog-public.txt)"`
  → 会下载两个架构产物（约 400 MB）并校验签名、SHA-256、大小、URL 形状。
- **完整构建**：需要网络与 macOS，且**会真的产生新产物**——除非明确要发布，否则不要跑
  `build-runtime.sh`。

## 11. 新工作区接管建议

1. **先读这 5 份**：`docs/migration/HANDOVER.md`（本文）→ `PROJECT_OVERVIEW.md` → `ARCHITECTURE.md` →
   `DECISIONS.md` → `DEVELOPMENT_STATUS.md`；随后按需读 `docs/runtime-contract.md`（契约权威）与
   `docs/key-custody-runbook.md`（P0）。
2. **先做只读核验**（§7 的 1–4 步），确认"文档说的状态 == 真实状态"，再动手。
3. **把冻结项抄进你自己的约束清单**（§5），尤其是"不要触发发布"与"不要改冻结契约"。
4. **第一个真正的任务**应该是 §8 的第 1 项（只读检查 cron）；除非工程级指令另有安排。
5. **保持本仓库独立性**：不要合并仓库、不要移动代码、不要重命名项目；需要跨仓库改动时，先提出方案。
6. **有疑问时先问**，尤其是涉及：发布、密钥、已发布产物、公开字段语义、跨仓库契约。
