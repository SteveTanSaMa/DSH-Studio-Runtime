# WORKSPACE MIGRATION — DSH-Studio-Runtime

> 历史记录：本文保存 2026 年 10 月的迁移现场。路径、Git 状态、待办和测试结果仅反映当时，不代表当前状态；现行 Runtime 契约以 [runtime-contract.md](../runtime-contract.md) 和仓库 [README](../../README.md) 为准。
> 签名密钥的保管与备份请参考 [key-custody-runbook.md](../key-custody-runbook.md)；本文不确认备份现状。

本文件记录把本项目从旧工作区迁移到统一工程目录的**实际执行结果**。所有数字与结论来自迁移脚本的
现场输出；未验证事项显式标注。

## 1. 迁移信息

| 项 | 值 |
| --- | --- |
| 项目名称 | DSH-Studio-Runtime（目录名 `DSH Studio Runtime`） |
| 原始绝对路径 | `/Users/stevetan/SteveTan/Document/Xcode/DSH Studio Runtime` |
| 新绝对路径 | `/Users/stevetan/SteveTan/Document/Developer/DSH Studio/DSH Studio Runtime` |
| 迁移时间（UTC） | `2026-10-12T18:29:18Z` |
| 迁移方式 | 同文件系统 `mv`（设备号 16777231，等价于重命名：不复制、不额外占用磁盘） |

## 2. 文件迁移结果

- **完成移动**：整个项目目录（含 `.git`、全部隐藏文件、未跟踪文件、文件权限）通过一次重命名迁入目标位置。
- **目标目录处理**：`Developer/DSH Studio/DSH Studio Runtime` 迁移前**已存在但为空**（0 个条目，含隐藏文件），
  先 `rmdir` 占位目录再移动，因此**没有产生多余嵌套**（脚本实测 `nested=0`）。
- **冲突**：无（目标为空、未覆盖任何已有文件）。
- **源位置残留**：无（脚本断言移动后旧路径已不存在；父目录 `Xcode/` 保留，因为其中还有其他项目）。

## 3. 路径修复记录

迁移前对整个项目做了绝对路径扫描（`*.md` / `*.sh` / `*.js` / `*.yml` / `*.txt` / `*.json`），
**只有一处**包含旧工作区路径，且属于迁移文档自身：

| 文件 | 原内容 | 修改后 | 原因 |
| --- | --- | --- | --- |
| `docs/migration/INTEGRATION.md` | 把 MiPlay 记为 `/Users/stevetan/SteveTan/Document/Xcode/MiPlay`；DXMT/LSFG 记为「未找到」 | 改为迁移后在 `Developer/MiPlay/` 下的**实际核实位置**（含各仓库 HEAD），并保留「与本项目无已证实关系」的判断 | 其他仓库的位置随本次工程迁移变化，需与实际文件系统一致 |

**无需修复的引用**（逐项判断，不是忽略）：

- 本项目**没有任何**指向 `DSH Studio`（App）的本地路径引用；`grep` 反向检查也确认 App 仓库不引用本项目的旧路径。
- MiPlay 仓库中也没有对本项目的引用（`grep -rl` 无命中）。
- 项目内部脚本全部使用相对路径、`$GITHUB_WORKSPACE`、`$SCRIPT_DIR` 或 `$HOME` 表达位置；构建与发布只依赖
  GitHub 上的 URL，不依赖本地目录。
- `.commandcode/`（开发工具本地状态）中**没有**绝对路径，无需修改。
- 项目内**没有** `AGENTS.md` / `CLAUDE.md` / `.agents/` / `.claude/` / `.cursor/` 等 Agent 配置文件，
  因此没有需要修复的项目级 Agent 配置。

## 4. 验证结果（迁移后现场执行）

| 检查 | 结果 |
| --- | --- |
| 工作区识别 | `git rev-parse --show-toplevel` = 新路径（脚本已断言） |
| Git 分支 / HEAD | `main` / `d6b3336920ab24dc0e07296865e8729e49e139ee`（与迁移前一致） |
| 未推送提交 | 1 个（迁移前既有：迁移文档提交，按约束未推送） |
| 未提交修改 |  M docs/migration/INTEGRATION.md |
| 目录嵌套检查 | 0（0 = 没有产生 `DSH Studio Runtime/DSH Studio Runtime` 这类嵌套） |
| 离线测试套件（新路径下执行） | 113 passed, 0 failed |
| 旧绝对路径残留 | **0 处**（扫描命中 1 条，逐条核对为**新路径本身**：`/Users/stevetan/SteveTan/Document/Developer`，属扫描模式 `/Users/stevetan` 的正常命中，不是旧引用） |
| 磁盘占用变化 | 无（重命名，未复制数据） |
| 已发布产物 / catalog / 签名密钥 | 未触碰 |

### 4.1 迁移后现场复核（补充证据）

| 检查 | 结果 |
| --- | --- |
| `git fsck` | 无输出（仓库对象完整） |
| 受版本控制文件数 | 35 = 迁移前的 28 + 本次新增的 7 份 `docs/migration/` 文档 |
| 顶层结构 | `.git` / `.github` / `Scripts` / `docs` / `keys` / 两个 README / `.gitignore` / `.commandcode` 全部在位 |
| 旧路径 | 已不存在（旧父目录 `Xcode/` 仅剩其他项目与 `.DS_Store`） |
| 磁盘 | 可用空间未减少（重命名，无复制） |
| 同工程的兄弟项目（只读观察，非本项目职责） | `Developer/DSH Studio/DSH Studio App` 已有 25 个条目；`Xcode/DSH Studio` 仍存在但 `.git` 已不在（其迁移由 App 侧 Agent 进行中）。`Developer/MiPlay/*` 三个仓库均已就位；`Developer/Forks/` 仅剩 1 个条目（空分类目录） |

### 4.2 工具侧影响（必须知道的运维事项）

**迁移后本 Agent 会话的默认工作目录（旧仓库根）已失效**：不带 `cwd` 的 shell 调用会直接失败
（`spawn /bin/sh ENOENT`）。已确认的解决方法：显式把工作目录设为新路径
`/Users/stevetan/SteveTan/Document/Developer/DSH Studio/DSH Studio Runtime` 后一切正常。
**后续任何工具体系（IDE、AI 会话、脚本）都应在新路径重新打开本项目**，不要再使用旧路径。

## 5. 未解决事项

1. **未提交的路径修复**：第 3 节对 `INTEGRATION.md` 的修改已写入工作区，但按本次约束**未提交、未推送**。
   需要仓库所有者决定提交时机（提交信息建议：`docs: point the integration notes at the migrated workspace`）。
2. **1 个未推送提交**：`d6b3336`（迁移文档）仍在本地 `main` 上，等待推送授权。
3. **本 Agent 会话的工作区**：迁移后本会话原工作区根路径已不存在；后续文件操作若失败，需在新路径
   `Developer/DSH Studio/DSH Studio Runtime` 重新打开工作区。**这不影响仓库本身的完整性。**
4. **跨项目状态（不属于本项目职责，仅记录）**：`Developer/DSH Studio/DSH Studio App` 迁移前为空（App 侧 Agent
   尚未迁移）；`Developer/Forks/` 迁移后为空目录（DXMT/LSFG 已按新结构移入 `Developer/MiPlay/`），
   是否清理由该工程的所有者决定。
5. **需要在外部工具里手动调整的设置**：如果 IDE / AI 工具 / 书签保存了旧路径
   `/Users/stevetan/SteveTan/Document/Xcode/DSH Studio Runtime`，需要手动更新——这些设置不在仓库内，
   本 Agent 无法访问或修改。
6. **未验证事项**（迁移不改变它们）：私钥离线备份仍是未解决的 P0；客户端 5 个缺口；跳过列表尚未遇到真实
   失败版本；真实 Intel 硬件；完整发布流程（迁移期间未触发任何发布）。

## 6. 最终迁移状态

**SUCCESS** — 文件已完整迁入新工程目录，Git 仓库可正常识别（分支/HEAD 与迁移前一致、未推送提交保留），
目标目录无覆盖、无嵌套，离线测试套件在新路径下 **113/113 通过**，旧绝对路径引用已逐项核对并修复。

剩余事项均为**需要所有者决定或跨项目协调**的条目（第 5 节），不属于迁移缺陷；因此不构成 PARTIAL/BLOCKED。
