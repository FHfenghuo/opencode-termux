# 改动清单（相对上游 `4d5965762ec5e0d1a0b14630553fc62b51a11fba`）

> 本文档逐文件说明：**改了哪个文件的哪些内容**、**为什么改**。
> 所有改动都可从 `build/` 重建：`bash build/build.sh`。
> 产物：`artifact/opencode`，sha256 见 `artifact/opencode.sha256`。

上游版本：`anomalyco/opencode` dev @ `4d5965762ec5e0d1a0b14630553fc62b51a11fba`（`v2.1.2-dev`）

---

## 0. 改动分层

改动分四层，**由外到内依次应用**，互不覆盖。理解这个分层是理解整个仓库的前提：

| 层 | 位置 | 内容 | 是否本仓库原创 |
|---|---|---|---|
| A. 上游 config delta | `upstream/opencode-bionic/termux/ci/versions.ts` | 改 `package.json` / `bunfig.toml`（版本号、catalog 别名、去掉 postinstall） | 否（第三方）|
| B. 上游 Termux 补丁 | `upstream/opencode-bionic/termux/patches/0001-termux-2x-port.patch` | 改 `packages/cli/script/build.ts`（构建绕坑） | 否（第三方）|
| C. 本包补丁 | `build/patches/000{1..4}-*.patch` | 构建 harness、回车行为、i18n、免密码 serve | **是** |
| D. 本包整树覆盖 | `build/overrides/` | `packages/app/vite-build.mjs` | **是** |

> **重要**：A、B 两层来自第三方 `opencode-bionic` 构建器，本仓库只原样 vendored。
> 改它们等于改第三方代码，重新 vendor 上游时会丢失 —— 所以本仓库的原创改动一律放 C、D 两层。

---

## 1. 本包补丁 (C 层)

### 1.1 `0001-bionic-build-harness.patch` —— 让构建能在 Termux/Bionic 下跑完

**根因**：Termux 下，一旦进程 `import "effect"`，**Bun 的异步线程池就不再 drain**。
任何依赖 `node:fs/promises`、`node:child_process` 的 shell promise、`node:zlib` 异步压缩的操作，
都会**永远挂住**：活儿干完了，但 promise 永不 resolve，整个构建卡死。

| 文件 | 改法 | 为什么 |
|---|---|---|
| `packages/cli/script/files.ts` | `readdir`(async) → `readdirSync`；递归由 `Promise.all` 改 `flatMap` | 避开不会 drain 的线程池；同步遍历完全不碰池 |
| `packages/cli/script/app-assets.ts` | `$\`bun run build\``(shell promise) → `spawnSync("node", ["vite-build.mjs"])` | shell promise 观察不到子进程退出；`spawnSync` 会真正等到子进程退出 |
| `packages/cli/script/app-assets.ts` | `promisify(brotliCompress)` → `brotliCompressSync`；`Promise.all` 改顺序 `map` | 异步 zlib 也走线程池，会永久挂起；同步压缩彻底绕开 |
| `packages/cli/script/app-assets.ts` | 去掉 `await`/`async`（函数保持签名兼容）| 与上面同步化一致 |
| `packages/cli/script/app-assets.ts` | `Bun.file(...).arrayBuffer()` → `readFileSync(...)` | 同上，避开 helper 的异步路径 |

> 这三处是**不可回退**的。回退任何一处，构建就会卡在「vite 已打印 built in 但进程不退出」。

### 1.2 `0002-app-enter-behavior.patch` —— 「回车发送 / 回车换行」设置

**背景**：上游 Web UI 的 Enter 键是**写死**的（Enter 发送、Shift+Enter 换行），没有设置项。

| 文件 | 改法 | 为什么 |
|---|---|---|
| `packages/app/src/settings/model.tsx` | 新增 `EnterBehavior` 类型；`generalSchema` 加 `enterBehavior: Schema.Literals(["send","newline"])`；`defaultSettings` 加 `enterBehavior: "send"`；新增存取器 `enterBehavior()` / `setEnterBehavior()` | 持久化设置的 schema + 默认值 + 读写口 |
| `packages/app/src/settings/general/general.tsx` | 新增 `EnterBehaviorSetting` 组件（`Select`，两个选项），挂进「设置 → 通用」 | 让用户能在 UI 里改 |
| `packages/app/src/composer/editor/interaction.ts` | `ComposerEditorView` 新增 `enterBehavior?: Accessor<"send"\|"newline">` | **关键**：把设置从 view 通道传给按键逻辑 |
| `packages/app/src/composer/editor/editor.tsx` | Enter 处理器改为读 `view.enterBehavior?.() ?? "send"`，据此决定是否 submit | 按键行为随设置变化 |
| `packages/app/src/composer/model.ts` | 引入 `useSettings`，在 `view` 里挂 `enterBehavior: () => settings.general.enterBehavior()` | 把设置接到 view 通道上 |
| `packages/app/src/settings/model.test.ts` | 期望值 fixture 加 `enterBehavior: "send"` | 否则 schema 测试失败 |

**为什么走 `view` 通道而不是 controller**：旧实现（历史交接包）读的是
`createComposerEditor()` 返回对象上**根本不存在的 `settings` 键**，导致 `?? "send"` 永远生效 ——
**设置被静默吞掉**（UI 能改、但按键行为不变）。正确通道是 `ComposerEditorView`。

按键行为矩阵：

| 设置 | Enter | Shift+Enter | Mod+Enter |
|---|---|---|---|
| `send`（默认）| 发送 | 换行 | 发送（alternate）|
| `newline` | 换行 | 发送 | 发送 |

### 1.3 `0003-app-enter-behavior-i18n.patch` —— 三语文案

| 文件 | 改法 |
|---|---|
| `packages/app/src/runtime/i18n/en.ts` | 加 `settings.general.row.enterBehavior.{title,description,send,newline}`（英文）|
| `packages/app/src/runtime/i18n/zh.ts` | 同上（简体：「回车键行为」「回车发送」「回车换行」）|
| `packages/app/src/runtime/i18n/zht.ts` | 同上（繁体：「Enter 鍵行為」「Enter 傳送」「Enter 換行」）|

`description` 里注入 `{{keybind}}` / `{{modKeybind}}`，展示随平台格式化的快捷键。

### 1.4 `0004-cli-serve-no-password.patch` —— serve 密码可选 + 默认端口

**背景**：上游 `opencode serve` **强制要求密码**（没有就 `Missing server password` 直接失败）。
本机自用场景不需要认证，且便利脚本（`ocs` 免密、`ocp` 带密码）需要能分别控制。

| 文件 | 改法 | 为什么 |
|---|---|---|
| `packages/cli/src/commands/commands.ts` | serve 命令加 `password: Flag.Boolean("password")`，别名 `-p` | 提供显式开关 |
| `packages/cli/src/commands/handlers/serve.ts` | 把 `input.password` 传给 `ServerProcess.run({ requirePassword })` | 免密/带密码由 CLI 明确控制 |
| `packages/cli/src/server-process.ts` | `Options` 加 `requirePassword?`；默认端口 `undefined` → **4096**；仅 `requirePassword` 时才生成/要求密码，否则 `password = undefined`；只有真生成了密码才打印 `server password` | 免密模式不再报错；裸 `serve` 固定 4096；不再打印 `undefined` |
| `packages/server/src/process.ts` | `start()` 去掉「无密码即失败」的硬检查；按有无密码提供 `ServerAuth.Config` layer；**`dispatch()` 仅在 `password` 非空时才调用 `authorizedRequest()`** | 无密码时 API 层真正放行 |

### 1.4.1 为什么上一版「免密」是假的（关键根因）

上一版只改了 CLI 和 `server/process.ts` 的启动检查，漏掉了 `dispatch()`：

```ts
function dispatch(password: string | undefined, ...) {
  const auth = password
    ? ServerAuth.Config.of({ password: Option.some(password), username: "opencode" })
    : ServerAuth.Config.of({ password: Option.none(), username: "opencode" })

  // ...
  if (/* ... */ !(yield* authorizedRequest(request, auth)))
    return unauthorizedResponse(request)
}
```

而 `ServerAuth.authorized()` 对 `Option.none()` 永远返回 `false`：

```ts
export function authorized(credentials, config) {
  if (Option.isNone(config.password) || ...) return false
  ...
}
```

所以 `dispatch()` 在**路由之前**就把每个 `/api/*` 请求打回 401。Web UI 的静态首页
（`cli/src/services/web-ui.ts` 里在 API 判断之前直接返回）仍然能打开，于是看起来
“没有密码、能进首页”，但浏览器一调 API 就要求认证 —— 这就是之前观察到的假免密。

修复方式是给 `dispatch()` 加 `requireAuth`，只在确实配置了密码时才做鉴权：

```ts
const requireAuth = typeof password === "string" && password.length > 0
// ...
if (requireAuth && !(yield* authorizedRequest(request, auth)))
  return unauthorizedResponse(request)
```

`authorizationLayer` 本身在无密码时已经放行（`ServerAuth.required(config)` 为
false 时直接返回原 effect），不需要再改。

> 这段改动原先只存在于构建树里，没有任何补丁记录；旧版只改了 CLI/启动层时**API 仍然要求密码**（假免密）。现在本补丁已包含完整修复（`dispatch()` 鉴权门控）。
> 若你**不想要免密 serve**，删除此补丁即可回到上游行为（上游默认强制密码）。

---

## 2. 本包整树覆盖 (D 层)

### 2.1 `build/overrides/packages/app/vite-build.mjs`

**新增文件**（覆盖到 `$TREE/packages/app/vite-build.mjs`）。

**为什么**：Termux 下 vite 的 `build()` promise **永不 resolve** —— 打包其实已经写完 `dist/`，
但异步清理（rolldown worker、临时文件）走那个不 drain 的线程池，promise 永远挂着。
所以不能 `await build()`，改为挂钩 `closeBundle`，**打包一写盘就 `process.exit(0)`**。
`dist/` 在那一刻已经是完整的。

> `build/overrides/` 是**整树覆盖**语义：目录层级原样映射到构建树。
> `build/overrides/packages/app/vite-build.mjs` → `$TREE/packages/app/vite-build.mjs`。
> **放文件时必须保留相对路径，不能平铺**，否则构建时报 `Cannot find module '.../vite-build.mjs'`。

---

## 3. 可复现性验证

四份补丁 + 一份覆盖，应用到干净的上游 clone 后，**逐文件与当前构建树一致**：

```bash
T=/data/data/com.termux/files/usr/tmp/opencode
rm -rf $T/verify-tree
git clone https://github.com/anomalyco/opencode.git $T/verify-tree
cd $T/verify-tree && git checkout 4d5965762ec5e0d1a0b14630553fc62b51a11fba
for p in /path/to/opencode-build/build/patches/000*.patch; do
  patch -p1 --forward -i "$p" || echo "FAIL $p"
done
```

应用结果（15 个源码文件）与构建树**逐字节一致**。

> 注意：主程序自身 sha256 **每次构建都会变**（Bun bundle 非逐字节可复现）。
> 「安装进去的确实是本仓库的产物」这一判断，看 `build/verify.sh` 第 4 步的
> **内嵌资产 sha256 比对**，而不是主程序 sha256。

---

## 4. 不纳入版本控制的构建输入

以下文件由构建脚本在运行时生成，**不属于原创源码**，不纳入补丁或 git：

| 文件 | 来源 |
|---|---|
| `package.json` | 上游 config delta（A 层，`versions.ts apply`）|
| `bunfig.toml` | 同上 |
| `bun.lock` | `bun install` 生成 |
| `node_modules/` | `bun install` 生成 |
| `.opencode-build/applied-patches` | `build.sh` 的幂等标记文件 |

---

## 5. 环境要求与已知坑

见 `README.md`「环境要求」与「注意事项」两节，以及 `docs/HANDOVER.md` 第 4 节。
最要紧的三条：

1. **不可回退异步化**：`spawnSync` / `readdirSync` / `brotliCompressSync` 是 Termux 下的唯一可行写法。
2. **`/tmp` 不可写**：临时文件放 `$HOME` 或 `$PREFIX/tmp`。
3. **构建前台单任务**：不要并发，否则会撞上线程池问题。
