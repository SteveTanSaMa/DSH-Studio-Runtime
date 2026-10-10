# Runtime catalog 签名密钥：托管、恢复与应急 Runbook

本文件是**操作流程**，不是"已经做过"的记录。仓库里没有任何地方能证明生产私钥存在离线备份；
在仓库所有者手动完成第 3 节并留下证据之前，必须假定**私钥只存在于 GitHub Secret 一处**。

## 1. 信任链现状（已核实）

| 环节 | 位置 | 证据 |
| --- | --- | --- |
| 私钥 | GitHub Actions environment `runtime-signing` 的 secret `RUNTIME_CATALOG_PRIVATE_KEY_BASE64`（PKCS#8 DER，base64） | `docs/runtime-catalog-keys.md:8`；`runtime-builder.yml` 只在 publish job 引用该 environment |
| 公钥锚 | 本仓库 `keys/runtime-catalog-public.txt`（`keyID=runtime-catalog-v1` + 32 字节公钥 base64） | 文件本身；`keyID` 行已核实 |
| 客户端锚 | **App 二进制内**：build setting `RUNTIME_CATALOG_PUBLIC_KEY` → `Info.plist` → `RuntimeCatalogTrust.publicKeyData(bundle:)` | `DSH Studio/Info.plist:31`、`Sources/Runtime/Catalog/Support/RuntimeCatalogTrust.swift:12-32` |
| 客户端 keyID 期望 | 常量 `runtime-catalog-v1` | `RuntimeCatalogTrust.swift:16`；校验点 `RuntimeCatalogService.swift:230` |
| 签名强制 | 派生公钥 ≠ 锚即拒绝签名 | `Scripts/sign-runtime-catalog.sh:60-72`（本次已用临时密钥复现，见第 4 节） |
| 验签 | 锚长度 / 信封 schemaVersion / keyID / 签名 / payload schemaVersion | `Scripts/verify-runtime-catalog.sh:37-70` |

**关键结论（代码证实）**：客户端只认**内置的那一把**公钥，进程内没有多锚、没有密钥列表、没有远程取锚。
因此**任何换锚都需要一次新的 App 发布**——这决定了下面"泄露"和"丢失"两种应急方案都涉及 App 发版。

## 2. 什么情况会导致签名能力丧失

| 情况 | 后果 | 可恢复性 |
| --- | --- | --- |
| Secret 被删除/覆盖且无备份 | 无法签名新 catalog；已发布的 catalog 仍可用，老客户端能装**当前**版本，但永远装不到**新**版本 | 只能换锚 + 发新版 App |
| GitHub 账号/仓库不可访问（封禁、误删、2FA 丢失） | 同上 | 同上 |
| Environment `runtime-signing` 误删/改名 | 流水线立刻失败（不是静默） | 重新创建 environment 并重新写入同一个 secret（需有备份） |
| 私钥文件/备份泄露给第三方 | 攻击者能签发任意 catalog（可指向恶意 Runtime）——这是**最严重**的失效模式 | 换锚 + 发新版 App；期间旧锚必须视为已污染 |
| 密钥材料被替换成另一把（与锚不符） | CI 立刻失败（`sign-runtime-catalog.sh:68-72`），不会发布错误签名 | 恢复正确的 secret 即可 |
| 备份存在但从未演练/校验 | 等于没有备份（恢复时才发现备份损坏或格式不对） | 见第 4 节的验证步骤 |

## 3. 备份（**尚未完成，需仓库所有者手动执行**）

AI/CI 无法读取 GitHub Secret 的明文（`gh secret list` 只显示名字与时间），所以备份必须由所有者手动完成：

1. 在可信终端复制 secret 的值（GitHub → Settings → Environments → `runtime-signing` → Secrets）。
2. 存入**两处独立介质**，均不得进入任何 git 仓库、issue、聊天或云笔记明文：
   - 密码管理器（受 2FA 保护）条目，标题注明 `DSH-Studio-Runtime runtime-catalog-v1 private key`；
   - 离线介质（加密 U 盘 / 打印的恢复码），与密码管理器分开存放。
3. 在备份条目里同时记录：`keyID=runtime-catalog-v1`、对应公钥（`keys/runtime-catalog-public.txt` 里的
   `publicKey` 值）、备份日期、以及"恢复后必须跑第 4 节验证"的提示。
4. 在仓库外记录**备份存在性**（不必记录密钥本身）：例如在私人的运维清单里标注
   "2026-XX-XX 已备份到 <介质A>/<介质B>，最近一次校验通过"。

## 4. 恢复与验证（本流程已用**临时密钥**完整演练）

演练环境：一次性 Ed25519 密钥对 + 临时锚文件，全程未接触生产 secret，临时私钥在用后即删除。
结果如下（`PASS` = 实际执行通过）：

| 步骤 | 命令要点 | 结果 |
| --- | --- | --- |
| 生成临时密钥对 | `crypto.generateKeyPairSync("ed25519")` → PKCS#8 DER base64 + 32 字节公钥 | PASS |
| base64 模式签名（= 恢复后 CI 的用法） | `RUNTIME_CATALOG_PRIVATE_KEY_BASE64=… RUNTIME_CATALOG_PUBLIC_KEY=<锚>` | PASS，打印派生公钥 |
| 用锚验签 | `verify-runtime-catalog.sh SIGNED PUB runtime-catalog-v1` | PASS |
| **恢复校验**：拿一把不匹配的私钥去签名 | 同上，但锚用 `keys/runtime-catalog-public.txt` | **拒绝**：`the signing key does not match the published trust anchor` |
| PEM 文件模式 | `RUNTIME_CATALOG_PRIVATE_KEY_PATH=<file.pem>` | PASS |
| **DER 文件模式** | `RUNTIME_CATALOG_PRIVATE_KEY_PATH=<file.der>` | **失败**：`error:1E08010C:DECODER routines::unsupported` |
| 篡改 payload 后验签 | 翻转 payload 一个字节 | **拒绝**：`the catalog signature is invalid` |
| keyID 不匹配 | `RUNTIME_CATALOG_KEY_ID=runtime-catalog-v2` | **拒绝**：`unexpected key ID` |

**所有者恢复时的最小验证**（等价于上表第 2/3/4 行，不需要发布任何东西）：

```sh
# 恢复出的私钥只放在当前 shell 的环境变量里，不落盘、不进历史
read -rs RUNTIME_CATALOG_PRIVATE_KEY_BASE64   # 粘贴备份中的 base64 值，回车
export RUNTIME_CATALOG_PRIVATE_KEY_BASE64
export RUNTIME_CATALOG_PUBLIC_KEY="$(sed -n 's/^publicKey=//p' keys/runtime-catalog-public.txt)"

# 用仓库自带脚本对一个临时 payload 签名：它会强制校验派生公钥 == 已提交锚
printf '{"schemaVersion":1,"runtimeVersion":"restore-check","releases":[]}\n' > /tmp/restore-check.json
./Scripts/sign-runtime-catalog.sh /tmp/restore-check.json /tmp/restore-check.signed.json
# 期望输出：Runtime catalog signed: … / Runtime catalog public key (base64): <与锚相同的 44 字符>
./Scripts/verify-runtime-catalog.sh /tmp/restore-check.signed.json "$RUNTIME_CATALOG_PUBLIC_KEY" /tmp/restore-check.payload.json
rm -f /tmp/restore-check.json /tmp/restore-check.signed.json /tmp/restore-check.payload.json
unset RUNTIME_CATALOG_PRIVATE_KEY_BASE64
```

**两条操作注意（本次演练发现）**：

1. `RUNTIME_CATALOG_PRIVATE_KEY_PATH` **只接受 PEM**；用轮换文档里生成的 PKCS#8 DER 字节会以
   OpenSSL 解码错误失败（`Scripts/sign-runtime-catalog.sh:56-58` 只在 base64 模式指定 `der/pkcs8`）。
   从备份恢复时用 **base64 环境变量模式**（如上），或把 DER 转成 PEM 再走文件模式。
   → 建议在后续阶段修一行：文件模式失败时按 `{key, format:"der", type:"pkcs8"}` 再试一次。
2. keyID 不是位置参数，而是环境变量 `RUNTIME_CATALOG_KEY_ID`（默认 `runtime-catalog-v1`），
   `verify-runtime-catalog.sh` 的 usage 里没有写。校验 keyID 必须用环境变量。

## 5. 定期验证（建议，尚未实施）

每月一次、只读、不产生任何发布：

- 人工：跑第 4 节的"最小验证"（3 条命令），确认备份可用且与锚一致；
- 若要自动化，可加一个 `workflow_dispatch` 的 **canary job**（不发布、不写 release）：用 environment
  `runtime-signing` 的 secret 对固定 payload 签名，再用 `keys/runtime-catalog-public.txt` 验签，
  失败即告警。它同时回答"secret 还在不在""锚还匹配不匹配"两个问题。
  **不要**把它放进 cron 的发布路径，也不要让它上传任何东西。

## 6. 泄露应急（攻击者拿到私钥）

1. **立刻**冻结发布：删除/停用 environment `runtime-signing` 的 secret（流水线将直接失败，这是期望行为）。
2. 生成新密钥对（见 `docs/runtime-catalog-keys.md` 的生成命令），更新 `keys/runtime-catalog-public.txt`
   （公钥 + 若需要则换 keyID），提交一个可 review 的 commit。
3. 更新 App 的 `RUNTIME_CATALOG_PUBLIC_KEY`（Debug + Release），**发布新版 App**。
4. 在新 App 发布**之后**，才用新密钥签发并发布 catalog。
5. 期间必须假定旧锚签出的 catalog 不可信；不要用旧密钥继续发布任何东西。
6. 复盘：私钥是怎么泄露的（导出到文件？终端历史？CI 日志？），并在备份流程里修掉。

**窗口不可避免**：客户端只认内置锚，因此从冻结到新 App 覆盖用户之间存在一段"老 App 无法发现新
Runtime"的时期（老 App 仍能用已安装版本与本地缓存离线工作）。

## 7. 丢失应急（备份丢失或不可恢复）

1. 先穷尽找回渠道：Environment secret 原文、密码管理器、离线介质、旧构建机/终端历史、
   任何曾导出过的 `.der/.b64`（本仓库 `.gitignore` 已按类型排除这些文件，但它们可能存在于旧机器）。
2. 若确实无法找回：
   - 已发布的 catalog 与 artifact 仍然有效，**已安装 Runtime 的用户不受影响**；
   - 但无法发布任何新版本（包括安全修复）；
   - 唯一出路与泄露方案相同：**换锚 + 发新版 App**。
3. 因此"丢失"与"泄露"的应急路径在技术上一致，区别只在于紧迫性和是否要复盘攻击面。

## 8. 是否需要支持信任锚轮换（评估）

- **当前状态**：单锚、编译进 App、无列表、无远程取锚（代码证实）。轮换 = App 发版，无法在 Runtime
  仓库内独立完成（`docs/runtime-catalog-keys.md:79-81` 已有同样结论）。
- **建议（跨仓库，非本阶段实施）**：在 App 侧把锚从"单值"改为"有序列表 + 显式激活索引"，
  预先内置一把**离线保存的备用公钥**。这样：
  - 丢失场景：用备用私钥签发，客户端只需一次配置切换（仍需发版更新"激活索引"，但可用预先发布的
    双锚版本提前覆盖用户）；
  - 泄露场景：仍必须发版，因为旧锚必须被废止。
- 收益是"把一次危机从'临时发版'变成'提前准备好的发版'"；成本是 App 侧一次改动。**本阶段只登记建议**。

## 9. 责任边界（避免误判）

- 本仓库可以做：写流程、用临时密钥演练、写 canary job 的设计、校验签名链路。
- 本仓库**不能**做：读取或复制生产 secret 明文；替所有者完成离线备份；在未经授权的条件下轮换生产密钥。
- "Runbook 已存在" ≠ "私钥已备份"。请以第 3 节的完成情况和第 5 节的校验记录为准。
