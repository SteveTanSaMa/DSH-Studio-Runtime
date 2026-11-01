# STORAGE CLEANUP REPORT — DSH Studio Runtime

> 历史记录：本文保存 2026-10-13 的本地清理过程。路径、空间占用、Git 状态和测试结果仅反映当时，不代表当前状态或本次重新验证的结果。
> 相关迁移经过见 [WORKSPACE_MIGRATION.md](../migration/WORKSPACE_MIGRATION.md)；现行 Runtime 契约以 [runtime-contract.md](../runtime-contract.md) 和仓库 [README](../../README.md) 为准。

日期：2026-10-13（Asia/Shanghai）。本次仅清理 `/Users/stevetan/SteveTan/Document/Developer/DSH Studio/DSH Studio Runtime`，未清理兄弟 App、父目录、系统或项目外共享依赖。

## 1. 清理前状态

`git rev-parse --show-toplevel` 确认上述目录为当前仓库。`docs/migration/WORKSPACE_MIGRATION.md` 记录完整仓库已于 2026-10-12T18:29:18Z 迁入；本项目迁移完成，不涉及迁移或恢复开发。

清理前 `du -k -s .` 为 **1580 KiB（1.543 MiB）**，包含隐藏目录。

| 一级目录 | 清理前占用 | 占总空间 |
| --- | ---: | ---: |
| `.git` | 1080 KiB | 68.35% |
| `Scripts` | 172 KiB | 10.89% |
| `docs` | 160 KiB | 10.13% |
| `.github` | 48 KiB | 3.04% |
| `.commandcode` | 48 KiB | 3.04% |
| `keys` | 4 KiB | 0.25% |
| 根目录文件 | 68 KiB | 4.30% |

最大子目录：`.git/objects` 928 KiB、`Scripts` 172 KiB、`docs` 160 KiB、`.git/objects/pack` 92 KiB、`docs/migration` 80 KiB、`.git/hooks` 64 KiB。

| 最大文件 | 分配空间 | 逻辑字节 |
| --- | ---: | ---: |
| `.git/objects/pack/pack-f351aadd2f5f30078ca20d37443745beb3649872.pack` | 80 KiB | 78404 |
| `Scripts/run-tests.sh` | 48 KiB | 46506 |
| `.github/workflows/runtime-builder.yml` | 32 KiB | 28683 |
| `README.en.md` | 28 KiB | 28512 |
| `README.md` | 28 KiB | 26876 |

缓存及构建产物 **0 KiB / 0%**；独立遗留历史测试数据 **0 KiB / 0%**；Finder 元数据 **64 KiB / 4.05%**，单独统计。

## 2. 用途分析与分类

遍历所有目录及普通文件（含隐藏文件），检查完整非 Git 文件清单、版本控制清单、忽略规则、构建与测试脚本。没有独立遗留测试输入/输出、测试数据库、日志、压缩包、旧实验目录、大型样本或发布产物。

测试 fixture 由 `Scripts/run-tests.sh` 中 `make_fixture` 等函数动态生成，使用 mktemp 隔离目录并以 EXIT trap 自动清理。`Scripts/tests/process-tree-scenarios.sh` 被当前测试明确引用，覆盖真实进程清理回归，必须保留。历史版本及迁移文档是技术证据，不是废弃测试数据。构建默认输出 `RuntimeArtifacts/`，本地没有该目录；正式构建和发布在 CI 执行。

- A 级：7 个 `.DS_Store`，与代码、测试、构建无关，可由 Finder 重建；预计释放 64 KiB。
- B 级：未发现验证后可删除的历史数据或旧产物。
- C 级：源码、配置、公钥、测试脚本、原有未提交文件、维护文档、Git 历史及工具状态，保留。
- 没有 node_modules、.venv、.build 或本地依赖下载缓存；清理无需下载依赖或重新编译。

## 3. 实际清理

按审计得到的具体路径逐项 unlink；确认普通文件、非符号链接、真实路径位于本仓库且内容摘要与审计一致。没有递归删除、废纸篓转移或大型备份。所有删除项原因均为 Finder 目录显示元数据，可自动重新生成；Git 内删除项也仅是 Finder 元数据。

| 删除路径 | 逻辑字节 | 分配空间 |
| --- | ---: | ---: |
| `.DS_Store` | 6148 | 8 KiB |
| `.github/.DS_Store` | 8196 | 12 KiB |
| `.commandcode/.DS_Store` | 6148 | 8 KiB |
| `.git/.DS_Store` | 6148 | 8 KiB |
| `.git/objects/.DS_Store` | 8196 | 12 KiB |
| `.git/logs/.DS_Store` | 6148 | 8 KiB |
| `.git/refs/.DS_Store` | 6148 | 8 KiB |

合计删除分配空间 **65536 字节（64 KiB）**，逻辑大小 47132 字节。没有其他确认安全的清理类别。

## 4. Git 审计及保留内容

`git count-objects -vH`：120 个松散对象，占 816 KiB；1 个 pack，110 个打包对象，pack 80.62 KiB；prune-packable=0、garbage=0、size-garbage=0。未发现异常膨胀或垃圾对象。未执行 gc、prune、reflog expire，未删历史、分支、标签、索引或引用。

保留清理后 `.git` 1044 KiB，包括对象、引用、reflog 和 fsmonitor IPC socket；保留 `.commandcode` 40 KiB，其中有 workflow、engineering、security、communication 规则及本地工具状态；保留双语 README、全部 docs、测试、CI 和公钥，因为维护、回归或发布仍需使用。

## 5. 待确认事项（按潜在空间排序）

| 内容 | 当前占用 / 潜在节省 | 原因及建议 |
| --- | ---: | --- |
| Git 数据库 | `.git` 1044 KiB；实际可节省量未估算 | 无异常，不建议为不足 1.1 MiB 牺牲历史；若后续评估保留历史的优化，须另行由用户决定，禁止自动强制回收 |
| `.commandcode` 工具状态 | 40 KiB / 上限 40 KiB | 无法认定规则和状态无价值；如用户明确弃用工具，可另行确认 |

没有需暂停等待授权的大型清理候选项。其他项目及外部共享缓存不在范围，未审计或清理。

## 6. 完整性验证

- 原有状态：` M docs/migration/INTEGRATION.md`、`?? docs/migration/WORKSPACE_MIGRATION.md`。清理后、写报告前 Git 状态完全一致；报告新增为未跟踪文件，未提交或推送。
- 对全部普通文件做清理前后 SHA-256 比较：除删除的元数据外，所有非 Git 原文件内容一致，原有未提交文件保留。Git 文件仅 `.git/index` 内容变化，发生于 Git 只读状态检查期间的索引刷新；工作区状态相同，索引未删除，源码未改动。
- 特殊 IPC socket 未读写；未发现符号链接，无越界清理。
- `git fsck --full`：退出 0，无异常输出。
- `git diff --check`：退出 0，无问题。
- `bash Scripts/run-tests.sh`：退出 0，**113 passed, 0 failed**。包含构建输入、签名、catalog、依赖审计、插件范围、进程清理、损坏产物负例、工作流引用和 Bash 语法检查。
- 本地 Node v26.3.1、Bash 3.2.57；无需安装、下载或调整开发环境。
- 测试创建的隔离临时数据由既有脚本清理，不生成大型项目缓存。未执行完整双架构构建或发布产物回下载，避免重建大型产物；真实 Runtime 启动及联网发布流程本次未重验。
- 未发现清理引起的问题；原有跨仓库待办和密钥备份状态参见迁移文档，本次不处理。

## 7. 空间结果及结论

清理后、写报告前 **1516 KiB**，减少 **64 KiB（4.05%）**。以下最终数据包含报告自身占用：

- 清理前 1580 KiB；最终清理后 **1524 KiB**；目录净减少 **56 KiB（3.54%）**。
- 报告分配空间：8 KiB。
- 文件系统可用空间观测：清理前 29965004800 字节，观测时 29936652288 字节，变化 -28352512 字节。该值受其他进程、APFS 分配和快照等影响，不能归因于本次清理；可归因删除量以 64 KiB 为准。

本次审计与所有可确认安全的清理已完成。项目必要开发内容保留，离线测试通过，正常开发能力未因删除内容受到影响。仓库本身很小，未发现大型无价值历史测试数据；进一步优化空间有限，需确认内容已列明。完成后停止，不恢复其他开发任务。
