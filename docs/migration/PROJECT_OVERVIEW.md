# PROJECT OVERVIEW — DSH-Studio-Runtime

> 本文供**完全没有参与过此前开发**的新 AI 对话快速理解本项目。基于仓库实际内容编写（2026-10-11，
> 提交 `7451b68`）。凡未能验证的事项均显式标注「待确认」。

## 1. 一句话定位

**DSH-Studio-Runtime 是 macOS 应用 DSH Studio 的「Runtime 构建与分发基础设施」**：把官方
DeepSeek Harness 打包成经过验证、可签名分发、可回滚的 Runtime 产物，供 Swift 客户端下载安装。

它**不是** Harness 的分支或重写，也**不是**客户端。它只做五件事：**构建、验证、签名、发布、发布后验证**。

## 2. 基本信息

| 项 | 值 |
| --- | --- |
| 项目名称 | DSH-Studio-Runtime（本地目录 `DSH Studio Runtime`） |
| 所属工程 | DSH Studio 工程（客户端 + Runtime 分发；迁移后纳入统一工程工作区） |
| 仓库 | `git@github.com:SteveTanSaMa/DSH-Studio-Runtime.git`（SSH） |
| 分支 / 当前提交 | `main` / `7451b68`（与 origin 同步，工作区干净） |
| 代码规模 | 28 个受版本控制文件，约 5,965 行（脚本 ~3,900 行、文档 ~2,000 行） |
| 技术栈 | Bash（构建/验证/发布脚本）、Node.js（少量结构化校验脚本）、GitHub Actions（唯一 CI/CD）、Ed25519（签名） |
| 构建产物 | `dsh-runtime-<harnessVersion>-<arch>.tar.gz` + manifest + 元数据 + 签名 catalog |
| 当前阶段 | 稳定维护（开发已冻结，等待工程工作区迁移） |
| 关键外部依赖 | 官方 `@deepseek-ai/dsh`（npm）、官方 Node.js 发行版、pnpm |

## 3. 它为什么存在（不可替代性）

官方 Harness 只提供**npm 包**与 **Electron 桌面应用**，没有任何可供第三方宿主复用的独立 Runtime
产物（npm 包不含 Node 二进制；桌面 Host 包是 `private` 且从不发布；安装包是签名终端用户安装器）。
而 DSH Studio 是 **Swift + WKWebView** 应用，必须自己解决：

1. **自带运行时**：用户机器上不能假定有 Node，也不能跑 Electron 的 Node；
2. **独立更新**：Harness 每周多次发布，客户端不可能跟着发版；
3. **可验证与可回滚**：下载的字节必须能认证、能失败回滚、不能破坏用户数据。

本项目就是这三件事的答案。细节见 `ARCHITECTURE.md` 与 `INTEGRATION.md`。

## 4. 主要功能（当前实际具备）

- **版本发现**：每小时轮询官方 Harness release，按发布时间升序选出"尚未构建"的版本（支持显式跳过列表）。
- **确定性构建**：固定 Node 版本（官方 `SHASUMS256.txt` 校验）、固定 pnpm 版本、精确 Harness 版本；
  `--ignore-scripts` 安装 + 依赖脚本审计 + 原生模块加载校验。
- **打包**：排序成员、固定 owner、去 macOS 元数据、`gzip -n` 的 tar.gz。
- **Smoke 验证**：对**解包后的产物**启动 Harness，验证原生模块、pty、封装（sandbox/credentials）、
  插件市场安装、SIGTERM 与进程树清理。
- **签名 catalog**：Ed25519 签名（私钥仅在 GitHub Actions environment `runtime-signing`），
  公开信任锚同时提交在仓库与客户端二进制内。
- **发布防降级**：同版本可重打包（替换附件），版本回退被拒绝（除非显式放行）。
- **发布后验证**：从公开 URL 回下载 catalog 与两个架构产物，验签 + 校验 SHA-256/大小/URL 形状。

## 5. 目录结构

```text
.
├── README.md / README.en.md        使用说明（中文为准，英文为镜像）
├── keys/runtime-catalog-public.txt 客户端信任锚（公钥，公开）
├── Scripts/                        全部构建、验证、发布、测试脚本（见 ARCHITECTURE.md §2）
│   ├── lib/process-tree.sh         进程树记录/断言/清理（smoke 与测试共用）
│   ├── tests/process-tree-scenarios.sh 真实进程场景测试
│   └── skipped-runtime-versions.txt    显式跳过列表（版本 | 截止日期 | 原因）
├── .github/workflows/
│   ├── runtime-builder.yml         构建 → smoke → catalog → 签名 → 发布 → 发布后验证
│   └── verify.yml                  PR/main 门禁：离线测试套件（无 secret）
└── docs/                           契约、版本、密钥、数据兼容、设计与 Runbook
```

## 6. 运行环境与入口

- **构建/发布只在 GitHub Actions 上跑**（`macos-14`/`macos-15` runner，x64 通过 Rosetta）。
  本地不需要私钥：日常开发、测试、smoke 全部可离线/本地完成。
- **入口脚本**：`Scripts/run-tests.sh`（离线测试，113 项）、`Scripts/build-runtime.sh`（单架构构建，
  需要网络）、`Scripts/runtime-smoke.sh`（对已解包产物运行）。
- **工作流入口**：`workflow_dispatch`（手动指定版本）、`runtime-<version>` tag push、每小时 cron。

## 7. 当前状态摘要

- 已发布：`0.2.0-rc.1`、`0.2.0-rc.2`、`0.2.1-alpha.1`、`0.2.1-alpha.2`（最新）；`runtime-catalog` 为
  GitHub Latest 之外唯一的固定分发入口。
- 测试：离线套件 113/113 通过（本地 + CI）。
- **开发已冻结**，等待工程工作区迁移；当前没有进行中的功能开发。
- **未解决的 P0 运维风险**：签名私钥的离线备份尚未确认（见 `docs/key-custody-runbook.md`）。

下一份应读的文档：`HANDOVER.md`（交接与接管建议）。
