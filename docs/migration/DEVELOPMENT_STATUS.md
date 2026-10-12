# DEVELOPMENT STATUS — DSH-Studio-Runtime

> 记录时间：2026-10-11，更新于 2026-10-12（提交 `7451b68`，工作区干净，`main` 与 origin 同步）。
> **开发已冻结**：本文件记录冻结瞬间的真实状态。凡未经验证的判断均显式标注。

## 1. 已完成且经过验证

| 项目 | 验证方式 | 证据 |
| --- | --- | --- |
| 离线测试套件 113 项 | 本地 macOS（bash 3.2）+ CI 均通过 | `Scripts/run-tests.sh`；run `verify.yml` 最近一次 success |
| 构建链路（Node 校验 → 依赖解析 → 审计 → manifest → 打包 → 解包 smoke） | 每次发布都在 CI 真实执行 | `.github/workflows/runtime-builder.yml` |
| arm64 真实产物 smoke | 对本机安装的 `0.2.1-alpha.2` 跑完整 smoke → 通过 | 2026-10-11 会话记录 |
| x64 真实产物 smoke（Rosetta） | 从 release 下载 `0.2.1-alpha.2` x64 → **SHA-256 与签名 catalog 一致** → 解包 → 完整 smoke 通过 | 同上 |
| 签名工具三种密钥输入（base64 DER / DER 文件 / PEM 文件）+ 篡改拒绝 | 新增 5 项回归测试；CI 通过 | `Scripts/run-tests.sh` 的 signing 段 |
| fs-ext 死代码清理 | 四个已发布版本的锁文件均无 fs-ext；两架构 smoke 通过 | Phase B 记录 |
| cron 版本选择重构 + 显式跳过列表 | 19 项离线测试（含到期/非法输入/fail closed/与防降级交互） | `Scripts/select-next-runtime-version.sh`、`run-tests.sh` |
| workflow 接线守卫（引用路径存在 + 读仓库的 job 必须 checkout） | 修复前失败、修复后通过 | `run-tests.sh` 的 workflow wiring 段 |
| 发布后验证（公开 URL 回下载） | 每次发布自动执行 | `verify-published` job |

## 2. 已实现但尚未充分验证

| 项目 | 缺什么 |
| --- | --- |
| ~~修复后的 schedule 选择逻辑在生产 cron 中执行~~ | **已验证（2026-10-12）**：修复（`7451b68`）后的三次 schedule run（`2026-10-11T20:20Z`、`2026-10-12T00:35Z`、`2026-10-12T07:25Z`，run `38217623761`）在 prepare 日志中正常输出选择器结果并以 `should_build=false` 结束，未发布任何版本。 |
| 跳过列表的**实际使用** | 只经过 fixture；尚未有一个真实版本因它被跳过。 |
| `dataFormat` 与真实数据格式的关系 | 已知二者不符（见 §4 已知问题），修正方案已设计未实施。 |
| x64 产物在**真实 Intel 机器**上运行 | 只有 Rosetta；无 Intel 硬件。 |
| build-runtime.sh 中 fs-ext 守卫的失败分支 | 需要完整构建才能触发；正常路径已由四个真实产物证明。 |

## 3. 正在进行 / 未开始

- **正在进行**：无（开发已冻结）。
- **已规划未开始**（均需跨仓库协调或明确指令，当前**不启动**）：
  1. 数据兼容字段切换（草案：`docs/data-compatibility-contract.md`，等 App 侧 B3/B4 稳定）。
  2. 插件市场解析职责收敛（设计只做到"识别问题"，未提出迁移方案）。
  3. App 侧三个缺陷的修复协同（见 §5）。
  4. 信任锚轮换能力（App 侧支持多锚 + 预置备用锚）。

## 4. 已知问题与技术债务

**本仓库内**

1. **P0 运维**：签名私钥的离线备份**未确认**。丢失/泄露都只能"换锚 + 发新版 App"。
   见 `docs/key-custody-runbook.md`（含已用临时密钥演练过的恢复步骤）。
2. **`dataFormat.id = "sqlite-v2"` 与事实不符**：真实数据是 `sessions/**.jsonl.zstd`（session format
   v4，实测）且不含 sqlite。该字段今天不触发任何隔离，属于"看起来有保护、实际没有"。
   设计好的替代方案（构建期从 `session-format-catalog` 派生代际）**未实施**。
3. **文档与实现的一处矛盾**：`docs/historical-versions.md:36-47` 一边承认数据是 jsonl，一边断言
   `sqlite-v2` 标签"正确"。修正随数据兼容方案一起做（避免单独改一半）。
4. **不可复现构建**：见 `ARCHITECTURE.md §8`。
5. **跳过列表需人工登记**：机制本身不自动检测"持续失败"。
6. **日期校验只做范围校验**（月 01-12、日 01-31），不覆盖日历上不存在的日期。

**跨仓库（客户端，只读审计发现；本仓库不能单方面修复）**

7. 客户端**不持久化 `artifact.sha256`**：安装身份只有"版本 + 依赖 pin + dataFormat"，无法区分同版本
   不同字节的两次构建（契约 `docs/runtime-contract.md` §6 要求三者）。
8. **同版本 repack 时缓存优先**：客户端的冲突规则会保留旧 catalog、丢弃更新的远端，导致校验永远失败
   （永久卡死，需要手删缓存文件）。
9. **staging 目录无启动清理**：崩溃残留 `.Runtime-<uuid>`（本机实测存在一个空的）。
10. **`.invalid` 僵局**：同版本内容冲突时既不更新也不启动已有安装。

## 5. 待验证事项（迁移时保留）

1. ~~修复后的 schedule 选择逻辑在真实定时任务中的首次执行结果~~ → 已只读核实（2026-10-12，三次 run，见上表）。
2. 跳过列表遇到真实失败版本时的行为。
3. 客户端修复后，`(runtimeVersion, architecture, artifact.sha256)` 身份是否真正落地。
4. 数据兼容契约的两处未验证细节：上游 `latestReleasedVersion` 记录与实际 alpha 线写入的差异；扫描
   profile 数据代际的客户端实现。
5. 真实 Intel 硬件上的 x64 运行。

## 6. 下一步建议（恢复开发时的顺序）

1. 只读检查下一次 cron 的 prepare 日志，确认新选择逻辑按预期（零候选、不发布）。
2. 与 App 侧对齐 B3/B4 的修复进度；在 App 稳定前**不切换任何公开字段语义**。
3. 协商数据兼容契约的迁移顺序（App 先能消费 → 双写 → 切换）。
4. 完成私钥离线备份（唯一需要人做、且不可由 AI 代劳的 P0）。
