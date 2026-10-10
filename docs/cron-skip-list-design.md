# Cron 版本发现：显式跳过列表设计（阶段 C 输入，**未实施**）

> 状态：**已实施（阶段 C）**。落地内容：`Scripts/select-next-runtime-version.sh`、
> `Scripts/skipped-runtime-versions.txt`，以及 `runtime-builder.yml` 中 schedule 分支的选择逻辑。
> 签名、构建内容、Catalog 生成、上传顺序、已发布产物与 Secret 均未改动。与设计的两处差异见文末。

## 1. 问题（代码证据）

`.github/workflows/runtime-builder.yml:112-152` 的 schedule 分支：把上游 release 按
`published_at` 升序排列，跳过 `UPSTREAM_MIN_HARNESS_VERSION`（含）之前的所有版本，然后对每个更晚的
版本依次判断：

1. `runtime-<version>` 已存在 → 记录日志并 `continue`（`gh release view`，`:137-140`）；
2. 上游 npm 包不存在 → 打 `::warning::` 并 `continue`（`npm view`，`:141-144`）；
3. 否则**选中该版本并 `break`**（`:145-147`）。

因此：**任何通过上面三道判断、但在构建/smoke 阶段永久失败的版本，会让此后每次 cron 都重新选中它，
并且永远不再尝试更新的版本**。构建失败不会被记录到任何持久状态里，所以"每小时重试、永远轮不到新版本"
是必然结果，而不是偶发。

现状缓解：`UPSTREAM_MIN_HARNESS_VERSION = 0.1.7-rc.2` 把已知无法重建的旧版本挡在下面；近 100 次
schedule run 全部成功，说明**目前没有**卡住的版本。楔子是结构性的，不是当前故障。

## 2. 验收标准（本设计的判据）

1. 保留自动发现上游新版本的能力；
2. 某个版本持续失败不得永久阻塞所有后续版本；
3. 不得静默跳过失败版本；
4. 跳过行为必须可审计；
5. 不得意外发布低于当前 Catalog 的版本；
6. 不得破坏现有防降级规则；
7. 不引入外部数据库或调度服务。

## 3. 方案对比

| 方案 | 行为 | 维护成本 | 缺点 | 结论 |
| --- | --- | --- | --- | --- |
| **A. 显式跳过列表（推荐）** | 仓库里一个文本文件列出"不要尝试"的版本 | 低（一次提交 = 一条记录） | 需要人工登记（但正是"不静默"的来源） | ✅ |
| B. 连续失败次数上限 | 自动统计失败并跳过 | 中：需要跨运行状态（分页查询 Actions API 或提交文件回仓库） | 自动跳过会掩盖间歇性失败（registry 抖动也会失败），且状态来源脆弱 | ❌ |
| C. 手动批准跳过 | 由 dispatch 输入决定跳过谁 | 低 | 需要一次手动 dispatch 才能生效，失败窗口更长 | ❌（A 已含其优点） |
| D. 解耦"发现"与"构建" | 发现 job 产出候选清单，构建 job 逐个处理 | 高 | 等价于 B 的状态机，且要改整个 workflow 结构 | ❌ |

选择 A：状态只有一个可 review 的文本文件，没有新的基础设施，失败行为在日志里完全可见。

## 4. 设计明细

### 4.1 跳过文件

位置：`Scripts/skipped-runtime-versions.txt`（与使用它的脚本放在一起，便于一起 review）。

格式（管道分隔，`#` 开头为注释；空白行忽略）：

```text
# version | until      | reason
0.1.7-rc.3 | 2027-04-01 | 上游依赖图今天无法启动；到期后自动重试（见 docs/historical-versions.md）
```

规则：

- **`until` 必填**（`YYYY-MM-DD`）：任何版本都不会被永久跳过；到期后该条目自动失效，cron 会重新尝试，
  并在日志里说明"跳过已到期，恢复尝试"。
- 条目**必须**带非空 reason；
- 解析失败（字段数不足、`until` 非法）→ **fail closed**：整个 run 失败并指出文件里的行号，
  绝不"当作没有跳过文件"继续（否则一个 typo 会静默改变发布行为）。
- 每次 run，对每个命中的条目打 `::warning::Skipping <version> until <date> — <reason>`。

### 4.2 选择脚本（建议单独成文，便于离线测试）

`Scripts/select-next-runtime-version.sh`，纯文本输入输出、无网络：

```text
用法: select-next-runtime-version.sh \
        --releases UPSTREAM_TSV \        # gh api … | jq …，每行 "tag<TAB>published_at"，升序
        --existing EXISTING_TXT \        # 每行一个已存在的 runtime tag
        --floor VERSION \                # UPSTREAM_MIN_HARNESS_VERSION
        --skips PATH                     # 跳过文件（缺失 = 无跳过）
```

- **stdout**：候选版本，按输入顺序升序，每行一个（已被 release 覆盖的、被跳过的不出现）；
- **stderr**：诊断与 `::warning::`（"already exists"、"skipped by list"、"skip expired"、"floor not found"）；
- 退出码：`0` 正常；`2` 输入/跳过文件格式错误（fail closed）。

workflow 侧只需把现有 while 循环替换为：

```bash
mapfile -t candidates < <("$SCRIPT_DIR/../Scripts/select-next-runtime-version.sh" …)
for candidate in "${candidates[@]}"; do
  npm view "@deepseek-ai/dsh@$candidate" version … >/dev/null 2>&1 || { warn; continue; }
  runtime_version="$candidate"; break
done
```

（npm 可用性检查**留在 workflow**，因为它是网络调用；脚本只负责"谁值得试"，因此可以完全离线测试。）

## 5. 不变量核对（对应第 2 节）

| 判据 | 为什么成立 |
| --- | --- |
| 2 + 3 不永久阻塞、不静默 | 被跳过版本每次运行都会被 `::warning::` 点名并附原因与到期日；`until` 到期自动恢复尝试；没有"跳过一次就忘记"的状态 |
| 4 可审计 | 唯一状态是 git 里的文本文件（blame/PR 可追溯）+ 每次运行的日志；不产生任何隐式状态 |
| 5 不会发布更低版本 | 跳过只会**移除**候选；候选顺序仍是上游发布日期升序，且**唯一**会让 catalog 后退的路径仍由 `Scripts/check-catalog-precedent.sh` 拦截（现有 4 类降级测试覆盖）。若所有候选都被跳过，则 `should_build=false`（什么都不发），绝不会"退而发布旧版本" |
| 6 不破坏防降级 | 本设计不触碰 `check-catalog-precedent.sh`、`allow_catalog_downgrade` 语义或发布顺序（artifact 先、catalog 后） |
| 7 无外部设施 | 一个文本文件 + 一个纯函数式脚本 |

## 6. 计划中的测试（阶段 C 落地时）

离线 fixture，无需网络：

1. 无跳过文件时：选中 floor 之后第一个未被 release 覆盖的版本；
2. 跳过列表命中中间的版本 → 选中**更新的**下一个候选（楔子修复的核心断言）；
3. 已存在 release 的版本不出现，且 stderr 有对应诊断；
4. `until` 已到期的条目被忽略，并打"恢复尝试"警告；
5. 跳过文件格式错误 → 退出码 2，且 stdout 为空（fail closed）；
6. floor 不在输入里 → 无候选、退出 0（保持现有"宁可不发布"的行为）；
7. 候选保持升序（回归：避免选择逻辑引入逆序）；
8. 与 `check-catalog-precedent.sh` 的组合：用被跳过/被选中序列构造的 catalog 仍拒绝降级。

## 7. 残余风险（如实记录）

- 跳过条目会**延迟**该版本的发布；若上游后续修好（新传递依赖）而条目未到期，我们不会自动重试。
  缓解：`until` 必填且建议不超过一个季度；运行日志每周都会提醒它的存在。
- 人工登记意味着"有人必须看告警"。这不是自动化缺陷，而是把"静默跳过"换成"显式决定"的代价。
- 本设计**不**解决"构建失败原因不可见"的问题（那是 run 日志的职责）；它只保证一个失败版本不会冻结整条流水线。

## 8. 实施记录与差异

落地时间：阶段 C。落地文件：

- `Scripts/select-next-runtime-version.sh`（stdout = 候选，stderr = 诊断/警告，退出码 2 = 输入非法）；
- `Scripts/skipped-runtime-versions.txt`（当前只有注释头，即"今天没有跳过任何版本"）；
- `.github/workflows/runtime-builder.yml`：schedule 分支改为调用上述脚本，npm 可用性检查留在 workflow；
  另外删除了不再使用的 `UPSTREAM_RELEASE_TAG_PREFIX` 环境变量，并把 floor 的注释改成指向跳过列表。

与设计的差异：

1. **日期校验是范围校验**（`YYYY-MM-DD`，月 01-12、日 01-31），不做真实日历校验（跨平台 `date`
   行为不一致，且这里只需要一个可比对的截止日）。因此 `2027-02-31` 会被接受，但会被当作 2 月末
   之后处理——不影响"不可无限期跳过"的性质。
2. **新增一条总结性通知**：候选数与"首个候选失败时后面还有几个排队"会明确打印，用于回答
   "后续版本是否因此再次等待处理"。候选只有一个时会说明"它失败不会挡住任何其它版本"。

真实数据演练（不触发发布）：用线上 26 个上游版本 + 我方 5 个已发布 tag + 当前 floor 跑一次选择，
输出为**空**（`no candidate … nothing to build`），符合预期；再注入一个假的新上游版本，脚本正确
选中它并打印"唯一候选"通知。
