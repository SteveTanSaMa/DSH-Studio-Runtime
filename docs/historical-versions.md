# Historical Runtime versions

本文件记录**哪些 Harness 版本可以重建为可用的 Runtime**，以及为什么更早的版本不行。
结论：**当前只有 0.2.0 线（自 `0.2.0-rc.1` 起）可以重建并发布。**

## 为什么历史版本重建不出来

每次构建都会**重新解析依赖图**：`build-runtime.sh` 为固定的 `@deepseek-ai/dsh@<version>` 生成
`package-lock.json`，再 `npm ci`。Harness 的依赖范围是宽松的（`^0.1.5-alpha.2` 之类），所以今天
解析出来的传递依赖是**当年发布之后才出现的新版本**：

```text
为 Harness 0.1.5-alpha.2 构建时实际安装：
  @deepseek-ai/dsh-sandbox-local@0.1.5-rc.3      ← 比 harness 本身新两个版本
```

「旧 harness + 新传递依赖」这种混合图不是当年的 Runtime，而且不稳定：上游在 0.1.5 之前修掉的
启动期 bug 会重新出现，新依赖也会和旧 harness 的加载顺序冲突。

## 实测（本机 arm64，完整构建 + smoke）

| Harness 版本 | 结果 | 失败原因 |
| --- | --- | --- |
| 0.1.1-rc.2 | ✗ | 启动即崩：`user patch-layer watching requires the Cordis HMR service`（手工启动 0/5 次成功） |
| 0.1.2-alpha.2 | ✗ | 同上 |
| 0.1.3-alpha.2 | ✗ | 同上 |
| 0.1.5-alpha.1 | ✓ | — |
| 0.1.5-alpha.2 | ✗ | `Duplicate type name 'DSH_STARTUPINFOW'`（同一 tarball 手工启动 5/5 成功 → 加载竞态） |
| 0.1.5-rc.2 | ✓ | — |
| 0.2.0-rc.1 / 0.2.0-rc.2 | ✓ | — |

因此正式发布从 **`0.2.0-rc.1`** 开始；更早的版本标记为「不可重建」，不进入 catalog。

## 数据格式

数据格式标签（`dataFormat.id`）与「哪些版本能重建」是两件事：

- 上游会话数据库的破坏性变更发生在 **Harness 0.1.0-rc.8**（`dsh-session-persistence-sqlite`
  的 `SCHEMA_VERSION` 15 → 17），DSH Studio 把 rc8 之后的契约标为 `sqlite-v2`；
- 我们发布过的所有版本都在 rc.8 之后，所以 `sqlite-v2` 对它们全部正确，**不存在需要
  `sqlite-v1` 的版本**（该标签对应 Harness < 0.1.0-rc.8，本仓库从未发布）；
- 这些 Runtime 也**不含 sqlite**：`dsh-base` 从 0.1.1-rc.2 起依赖
  `dsh-session-persistence-jsonl`（后期再加 `dsh-storage-json`），实际数据是
  `DSH_HOME/sessions/**.jsonl.zstd` 与 `DSH_HOME/storages/*.json`。

如果将来要重建 Harness < 0.1.0-rc.8 的版本，dispatch 时把 `runtime_data_format_id` 指定为
`sqlite-v1`；构建脚本本身按参数写入，不需要改动。

## 对自动发布的影响

`runtime-builder.yml` 每小时的轮询会从 `UPSTREAM_MIN_HARNESS_VERSION` 之后开始寻找「尚未构建」
的官方版本。该值必须停在**最后一个不可重建的版本**上，否则轮询会反复尝试构建一个永远失败的
旧版本，并且永远轮不到更新的版本。当前取值为 `0.1.7-rc.2`（0.2.0 线之前的最后一个版本）。
