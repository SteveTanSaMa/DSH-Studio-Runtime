# Runtime catalog signing keys

DSH Studio 只信任由一对特定 Ed25519 密钥签名的 Runtime catalog。这对密钥分处两地，
两半**必须始终描述同一对密钥**：

| 半 | 位置 | 用途 |
| --- | --- | --- |
| 私钥 | GitHub Actions environment `runtime-signing` 中的 secret `RUNTIME_CATALOG_PRIVATE_KEY_BASE64`（仓库 `SteveTanSaMa/DSH-Studio-Runtime`） | 发布时签名 catalog |
| 公钥 | 本仓库 [`keys/runtime-catalog-public.txt`](../keys/runtime-catalog-public.txt)，以及 DSH Studio target 的 `RUNTIME_CATALOG_PUBLIC_KEY`（`DSH Studio.xcodeproj/project.pbxproj`，Debug **和** Release，经 `Info.plist` 暴露） | 客户端的信任锚 |

签名素材以 base64 编码的 **PKCS#8 DER** 字节提供。发布流水线每次都会签名，日常开发不需要
本地私钥。

两个 job 的分工是刻意的：构建 job 不引用 `runtime-signing` environment，因此拿不到私钥；
只有 publish job 能看到它，且该 environment 会为每次发布留下审计记录。

## 不变量：签名密钥必须等于发布过的信任锚

signing 脚本（`Scripts/sign-runtime-catalog.sh`）要求同时提供 `RUNTIME_CATALOG_PUBLIC_KEY`，
并在派生公钥与它不一致时**拒绝签名**。`runtime-builder.yml` 从
`keys/runtime-catalog-public.txt` 读取这个值，所以：

- 改信任锚 = 改这个文件，是一次可 review 的提交；
- 只更新 secret 而不更新文件（或反之）会让 CI 立刻失败，而不是让已发布 App 静默失去
  远程发现能力。

## 校验当前线上 catalog

```sh
./Scripts/verify-runtime-catalog.sh \
    <(curl -sL https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-catalog/runtime-catalog.signed.json) \
    "$(sed -n 's/^publicKey=//p' keys/runtime-catalog-public.txt)"
```

验证线上 catalog 与 artifact 的完整链路（验签 + 逐个校验 SHA-256 和 URL 形状）：

```sh
./Scripts/verify-published-runtime.sh 0.2.0-rc.1 \
    "$(sed -n 's/^publicKey=//p' keys/runtime-catalog-public.txt)"
```

发布流水线的 `verify-published` job 每个版本都会自动跑同一套检查。

确认 App 侧的值一致（在 App 仓库里执行）：

```sh
grep -m1 RUNTIME_CATALOG_PUBLIC_KEY "DSH Studio.xcodeproj/project.pbxproj"
```

`keyID` 也必须与 `RuntimeCatalogTrust.keyID`（`runtime-catalog-v1`）一致。只换密钥材料、
不换 `keyID` 时，客户端不会因为 keyID 而拒绝，**但仍然会因为签名不匹配而拒绝**，所以两者
必须同时更新并同时发布 App。

## 轮换密钥

1. 生成新的 Ed25519 密钥对，并导出 PKCS#8 DER（base64）与对应的 32 字节公钥：

   ```sh
   umask 077
   node -e '
   const c = require("crypto");
   const { privateKey } = c.generateKeyPairSync("ed25519");
   const der = privateKey.export({ format: "der", type: "pkcs8" });
   console.log("RUNTIME_CATALOG_PRIVATE_KEY_BASE64=" + der.toString("base64"));
   console.log("RUNTIME_CATALOG_PUBLIC_KEY=" +
     c.createPublicKey(privateKey).export({ format: "der", type: "spki" })
      .subarray(-32).toString("base64"));
   '
   ```

   私钥只在可信终端里出现：不要重定向到文件、不要留在 shell 历史、不要贴进 issue/PR。

2. 把私钥写入 environment `runtime-signing` 的 secret `RUNTIME_CATALOG_PRIVATE_KEY_BASE64`。
3. 更新 `keys/runtime-catalog-public.txt` 的 `publicKey`（如有必要一并更新 `keyID`）。
4. 更新 App target 的 `RUNTIME_CATALOG_PUBLIC_KEY`（Debug 与 Release），发布新的 App 版本。
5. 在 App 版本发布**之后**再发布使用新密钥签名的 catalog，并先跑一次
   `Scripts/verify-published-runtime.sh` 确认签名链路。

顺序上有不可消除的窗口：客户端只认内置的那一把公钥，因此“换 catalog 签名密钥”与
“App 换信任锚”之间必然存在一段时间旧 App 无法发现新 Runtime（它们仍能用已安装的 Runtime
和本地缓存离线工作）。所以轮换应当与一次 App 发布同步进行，而不是在 Runtime 仓库里单独完成。

## 退役密钥

被替换的密钥对应放在构建机的 `~/.config/dsh-studio/retired/` 下并标注清楚，绝不用于签名
catalog。这只是操作约定，仓库和 CI 都不依赖该目录。
