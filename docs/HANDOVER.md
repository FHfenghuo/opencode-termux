# OpenCode Termux / Bionic 项目交接文档

> 交接时间：2026-10-22（安装器与文档于 2026-10-23 重写校对）
> 目的：让接手的会话 / 开发者**无需历史对话**即可继续工作。
> 配套：`README.md`（入口）、`docs/ARCHITECTURE.md`（架构）、`docs/INSTALLER.md`（安装器设计）、
> `docs/ARTIFACT-ANALYSIS.md`（产物分析）、`docs/TROUBLESHOOTING.md`（排障）

---

## 0. TL;DR

- 目标：为 **Android / Termux（Bionic，零 glibc）** 构建并安装 **OpenCode v2**，含 **Web UI**，
  并新增「回车行为」设置（Enter 发送 / Enter 换行）。
- 本轮完成的事：

  | # | 问题 | 结论 |
  |---|---|---|
  | 1 | `opencode serve` → `dlopen failed: library "libc.so.6" not found` | **已修复**：npm 上的 `bun-pty` 预编译 `.so` 是 glibc 链接的；换成 Bionic 版重建，产物内嵌的 PTY 库 `NEEDED` 只剩 `libc.so`/`libdl.so` |
  | 2 | Web UI「回车发送/换行」设置失效 + 未汉化 | **已修复**：设置项走 `view` 通道注入（老代码读 controller 上不存在的 `settings` 键，设置被静默吞掉）；i18n 补 en/zh/zht |
  | 3 | `opencode serve` 强制要密码 | **已修复**：新增免密 `serve`（`0004` 补丁）；`ocs` 免密、`ocp`/`ocsp` 带密码 |
  | 4 | 目录混乱、路径不统一 | **已重构**：`env.sh` 为路径唯一真源；`build-changes/` 并入 `build/patches/`+`build/overrides/`；`builder/` → `upstream/opencode-bionic/` |
  | 5 | 安装器流程随意、带历史回滚 | **已重写**：固定串行流水线（定位 → 哈希闸门 → 权限 → 依赖 → 部署），去掉回滚/多版本，见 §8 |

- 当前产物：**v2.1.2-dev**，199 821 576 B（191 MiB），
  sha256 `25cde8a86433852d9e981efde4ee5c1a477dee96bf483d5e14469a0433edb50e`
  （Bun bundle 非逐字节可复现，每次构建都会变；稳定判据是 `build/verify.sh` 第 4 步的
  **内嵌资产 sha256 比对**）。
- 安装布局：ELF 在 `$HOME/.local/share/opencode/opencode`，启动脚本在 `$HOME/opencode/bin/`，
  命令软链在 `$PREFIX/bin/`（见 §3.2）。

---

## 1. 硬约束

> ### ⛔ 绝对禁止 glibc
> 本项目**必须完全使用 Bionic**。glibc 的 `.so` 不能以任何形式留在产物里，
> **不要**引入 glibc 兼容垫片 / shim / `patchelf` 重定向之类的方案。
> glibc 的兼容在 Android 上不可靠。正确的做法永远是「用 Bionic 版重新构建」。

---

## 2. 项目背景

### 2.1 为什么要自建
- 官方 OpenCode 只发布 **glibc** 的 Linux 二进制，**无法在 Termux/Bionic 上直接运行**。
- 社区有第三方 Bionic 构建仓库 `bd-loser/opencode-bionic`，跟踪上游 `anomalyco/opencode`。
- 上游**没有 v2 稳定版**，最新稳定是 v1.19.3；用户明确选择最新 dev 线。

### 2.2 需求（按优先级）
1. **零 glibc**：全部依赖 Bionic（`bun-termux`、`@androidtui`、Bionic 版 `bun-pty` / `pty-service`）。
2. **Web UI 可用**：配对后根路径不能 404。
3. **回车行为设置**：Enter = 发送 vs Enter = 换行，**默认「发送」**（保持原行为）。
4. **构建能正常结束**，不卡死，产物无运行时报错。
5. 安装脚本：菜单、环境检测、依赖安装、命令注册、卸载清理。**不做历史回滚 / 多版本**。
6. 构建必须**前台单任务**执行。
7. 目录职责清晰、路径统一管理。

---

## 3. 目录与路径（重构后）

### 3.1 包内（`opencode-build/`）

目录职责的权威定义见 `docs/ARCHITECTURE.md` §1，这里不再重复整张表。交接时必须知道的边界：

- `env.sh` —— 构建/校验脚本的路径真源；安装器为独立分发，不 source 它，但路径口径必须一致。
- `artifact/` —— 只放成品二进制与校验和；ELF 不进 git，走 Release。
- `installer/` —— 唯一安装器；不再保留旧的根目录安装脚本或多版本目录。
- `build/patches/` —— **本包原创**补丁；第三方补丁只在 `upstream/opencode-bionic/termux/patches/`。
- `build/overrides/` —— **本包原创**整树覆盖；目录层级原样映射到构建树。
- `upstream/opencode-bionic/` —— 第三方 vendored 构建器，不在这里改业务逻辑。
- `docs/` —— 随仓库发布；文档职责见 `docs/ARCHITECTURE.md` §4。

### 3.2 设备上的关键路径

| 路径 | 说明 |
|---|---|
| `$HOME/.local/share/opencode/opencode` | **ELF 本体**（真实文件，`chmod 700`）|
| `$HOME/opencode/bin/<name>` | 启动脚本（真文件，含 `exec`）|
| `$PREFIX/bin/<name>` | 全局命令入口（软链 → `$HOME/opencode/bin/<name>`）|
| `$HOME/.config/opencode`、`.cache/opencode`、`.local/state/opencode` | 配置 / 缓存 / 状态 |
| `~/src/build-tree/` | **构建树**（默认位置，`env.sh` 的 `OPENCODE_BUILD_TREE`）|
| `~/src/build-tree/packages/cli/dist/cli-linux-arm64/bin/opencode` | 构建产物 |

> 安装器**不**使用 `~/opencode/versions`、`current`、`previous`、`install.sh` 这类结构
> —— 那是旧的「多版本 + 回滚」安装器留下的，已废弃（见 §8）。

### 3.3 路径统一：为什么要有 `env.sh`

重构前的问题：安装器、构建脚本、校验脚本各自硬编码路径，改一处要改三处。
现在构建侧脚本统一走 `env.sh`：

```bash
source ./env.sh
opencode_artifact_candidates   # 构建侧脚本的查找顺序
```

> **安装器是特例**：`opencode-termux.sh` 为「可独立复制运行」而**不** source
> `env.sh`，它自带 `find_elf()`（显式路径 > 当前目录候选 > 深度搜索）。
> 两者口径**不必相同**，各自服务不同场景。详见 `docs/ARCHITECTURE.md` §1.1 / §2.3。

---

## 4. ⚠️ 构建卡死根因与修复（最关键，务必保留）

### 4.1 唯一根因
**构建流程会 `import "effect"`。在 Termux/Bionic 下，Bun 一旦加载 effect，其异步线程池（thread pool）就不再 drain。**

由此衍生出**三个**卡死点，表象不同、根因相同：

1. `` $`bun run build` `` —— shell promise 永远等不到子进程结束。
2. vite 的 `build()` —— 产物已写完（打印 `✓ built in`），但 promise **永不 resolve**。
3. `readdir`（异步）/ `brotliCompress`（异步）—— 在 thread pool 上**永久挂起**（CPU 0%）。

> 验证方法：只 `import "effect"` + 跑 vite 即可复现；不 import 则正常。

### 4.2 修复（全部改走同步 / 独立进程）

| 文件 | 改动 | 原因 |
|---|---|---|
| `packages/cli/script/app-assets.ts` | `` $`bun run build` `` → `spawnSync("node", ["vite-build.mjs"])` | `spawnSync` 不依赖事件循环 |
| `packages/cli/script/app-assets.ts` | `brotliCompress` → `brotliCompressSync`，`readFile` → `readFileSync` | 避开死掉的线程池 |
| `packages/cli/script/files.ts` | `readdir`（promises）→ `readdirSync` | 同上 |
| `packages/app/vite-build.mjs`（**新增**） | vite `build()` API + `closeBundle` 钩子内 `process.exit(0)` | 打包完成即强制退出，不等卡死的异步清理 |

对应本包补丁：`build/patches/0001-bionic-build-harness.patch`；
整树覆盖：`build/overrides/packages/app/vite-build.mjs`（→ `$TREE/packages/app/vite-build.mjs`）。

### 4.3 其它社区补丁（保留，勿回退）
`packages/cli/script/build.ts`（由上游 `upstream/opencode-bionic/termux/patches/0001-termux-2x-port.patch` 提供）：

- `@opentui/*` → `@androidtui/*` 别名插件
- Bionic 下 `@opencode-ai/pty`、`@parcel/watcher` 无 android 二进制 → 降级
  （pty 回退 `child_process`，watcher 轮询）
- **`bytecode: false`**、**`splitting: false`**（Bun 字节码/分包在 Bionic 下有问题）
- `resolveOpencodePty` 失败在 Termux 上**不致命**（改为非 glibc 目标时直接跳过）

### 4.4 复现 / 调试配方
```bash
# 1) 确认 effect 是元凶（会卡住）：
cd ~/src/build-tree
printf 'import { $ } from "bun"\nimport "effect"\nawait $`node node_modules/vite/bin/vite.js build`.cwd("packages/app")\n' > t.ts
bun t.ts   # 会卡在 "built in" 后不退出

# 2) 不 import effect（正常退出）对比。
```

---

## 5. PTY：零 glibc（问题 1 的完整解法）

### 5.1 根因
`bun-pty@0.4.11` 在 npm 上发布的预编译 `librust_pty_arm64.so` 是 **glibc 链接**的：

```
NEEDED: libc.so.6  libpthread.so.0  libdl.so.2  libutil.so.1
```

`bun-pty/src/terminal.ts` 在**模块顶层**就 `dlopen` 这个 `.so`（第 120 行），
所以**只要 import bun-pty 就会触发**。Bionic 上找不到 `libc.so.6` → 报
`dlopen failed: library "libc.so.6" not found`。

### 5.2 修复路径（**不是**运行时兼容层，是重新构建）
1. 从 bun-termux release 取 **Bionic 版** `librust_pty_arm64.so`
   （`NEEDED` 只有 `libc.so` / `libdl.so`，`GLIBC_` 符号数为 0）。
2. 覆盖构建树里的
   `node_modules/.bun/bun-pty@0.4.11/node_modules/bun-pty/rust-pty/target/release/librust_pty_arm64.so`。
3. bun-pty 用**静态可分析的 `require()`** 嵌入这个 `.so`，
   所以**磁盘上这份文件就是产物里内嵌的那份** —— 覆盖后重建即可。
4. 构建后用 `build/scan-elf.ts` 核对内嵌切片与源文件 **sha256 完全一致**。

### 5.3 常驻 PTY 守护进程
`@opencode-ai/pty-linux-arm64-gnu` 这个可选依赖在 Android 上**不会被 npm 装上**
（`@opencode-ai/pty` 只发布 darwin/linux/win32 的 optionalDependencies）。
`resolveOpencodePty()` 因此会失败 → 守护进程不会进产物。

本包的做法（对齐 `upstream/opencode-bionic/termux/ci/build-in-container.sh`）：
手工创建 `node_modules/@opencode-ai/pty-linux-arm64-gnu/`，放入 Bionic 静态守护进程
`opencode-pty-android-aarch64`（2 920 272 B，**完全静态**，`NEEDED` 为空）+ 手写 `package.json`
（`exports` 需含 `./package.json` 与 `./bin/opencode-pty`，否则 `require.resolve` 子路径会失败）。

`build/build.sh` 第 7 步自动化了这件事。

### 5.4 验证
```bash
cd ~/src/build-tree/packages/core
bun -e 'const m = await import("bun-pty"); console.log("加载成功", Object.keys(m))'
bun -e 'const {spawn}=await import("bun-pty");
       const p=spawn("/system/bin/sh",["-c","echo PTY_OK; tty"],{cols:80,rows:24});
       let o=""; p.onData(d=>o+=d); setTimeout(()=>{console.log(o.trim());process.exit(0)},1500)'
```
实测输出：`PTY_OK` / `/dev/pts/2`。

---

## 6. 回车行为设置 + 汉化（问题 2 的完整解法）

### 6.1 原来的 bug
交接包里的实现读的是：

```ts
(props.controller as any).settings
```

但 `createComposerEditor()` 返回的对象**根本没有 `settings` 键** → 表达式恒为 `undefined`
→ `?? "send"` 永远生效 → 用户选了「回车换行」也没反应（**静默失效**）。

### 6.2 正确的注入点：**`view` 通道**
`view` 是 `Accessor` 的容器，天然适合放「响应式读取的设置值」，且**不依赖 controller 的内部结构**。

| 文件 | 改动 |
|---|---|
| `packages/app/src/composer/editor/interaction.ts` | `ComposerEditorView` 加 `enterBehavior?: Accessor<"send" \| "newline">` |
| `packages/app/src/composer/model.ts` | `import { useSettings } from "@/settings/model"`；`view: { …, enterBehavior: () => settings.general.enterBehavior() }` |
| `packages/app/src/composer/editor/editor.tsx` | 读 `view.enterBehavior?.() ?? "send"`（去掉 `(props.controller as any).settings`） |
| `packages/app/src/settings/model.tsx` | schema `enterBehavior: Schema.Literals(["send","newline"])`、默认 `"send"`、`export type EnterBehavior`、`enterBehavior` / `setEnterBehavior` 存取器 |
| `packages/app/src/settings/model.test.ts` | 默认值断言补 `enterBehavior: "send"` |
| `packages/app/src/settings/general/general.tsx` | 新增 i18n 版 `EnterBehaviorSetting`，挂在 `FollowUpBehaviorSetting` 之后 |

> 为什么不用 `use()`：`use()` 在没有 provider 时会抛错，而 `composer.stories.tsx`
> 用的是手写 mock，不会调 `createComposerModel`。

### 6.3 行为
| 设置 | Enter | Shift+Enter | Mod+Enter |
|---|---|---|---|
| `send`（默认） | 发送 | 换行 | 发送（alternate）|
| `newline` | 换行 | 发送 | 发送 |

### 6.4 i18n
只改 `en.ts` / `zh.ts` / `zht.ts`（`language.tsx:103-104` 的 `merge` 是 `{ ...base, ...flatten(locale) }`，
非英语 locale 缺 key 会自动回退英文；但 `zh.ts`/`zht.ts` 有 `type Keys = keyof typeof en` 的类型约束，
所以**必须三个都补**，否则 tsc 直接报错）。

新增 4 个 key：

```
settings.general.row.enterBehavior.title        回车键行为
settings.general.row.enterBehavior.description  选择回车是发送消息还是插入换行。设为换行模式后，使用 {{keybind}} 或 {{modKeybind}} 发送。
settings.general.row.enterBehavior.send         回车发送
settings.general.row.enterBehavior.newline      回车换行
```

description 含 `{{keybind}}`（shift+enter）与 `{{modKeybind}}`（mod+enter）两个参数，
UI 里用 `ft("shift+enter", t)` 之类的 keybind 格式化函数注入。

对应补丁：`build/patches/0002-app-enter-behavior.patch`、`build/patches/0003-app-enter-behavior-i18n.patch`。

### 6.5 产物验证（已实测）
```
runtime-*.js            : enterBehavior:I([`send`,`newline`])  默认 enterBehavior:`send`
                          enterBehavior:Q(()=>e.general?.enterBehavior, Z.general.enterBehavior)
shell-*.js              : 下拉选项 {value:`send`,label:t(...send)} / {value:`newline`,...}
                          onSelect → t.general.setEnterBehavior(e.value)
incompatible-server-panel-*.js :
                          view:{placeholder:k, enterBehavior:()=>g.general.enterBehavior()}
                          if(t.key===`Enter`&&!t.isComposing){
                            if(!((o.enterBehavior?.()??`send`)===`send`?!t.shiftKey:t.shiftKey||n)||(...))return;
                            e.controller.submit(...)
                          }
index-*.js              : zh 文案「回车键行为」「回车发送」「回车换行」
language-*.js           : en 文案
zht-CWaPMJzI.js         : 繁体文案「Enter 鍵行為」「Enter 傳送」「Enter 換行」
```

---

## 7. 构建与校验（问题 3 的落地）

### 7.1 `build/build.sh`（10 个阶段：0～9）
```
0  环境检查（bun / node / patch / git / curl / sha256sum）+ 读 upstream/opencode-bionic/versions.json
1  拉取上游固定 commit（必须用完整 sha，短 sha 会被 GitHub 拒绝）
2  上游 config delta：upstream/opencode-bionic/termux/ci/versions.ts apply
3  上游 Termux 补丁：upstream/opencode-bionic/termux/patches/*.patch
4  本包补丁 + 覆盖：build/patches/*.patch、build/overrides/*
5  bun install
6  嵌入 Bionic bun-pty .so（下载后按 env.sh sha256 校验）
7  嵌入 Bionic opencode-pty 守护进程（下载后按 env.sh sha256 校验）
8  构建：bun run script/build.ts --target=opencode-linux-arm64 --skip-install
9  归档到 artifact/ + 写包根相对路径的校验和
```

> ⚠️ 第 8 步**不要**加 `--skip-web-ui`（否则产物不含 Web UI）。
> ⚠️ **不要**在本机并行跑第二个构建 —— Bun 线程池在 Termux 下会互相干扰。

**资产版本与 URL 的唯一真源**是 `upstream/opencode-bionic/versions.json`，
第 0 步用 `read_json` 读出来（参数走环境变量传，避开 bun/node 的 `process.argv` 索引差异）。
`env.sh` 仅保存版本与内嵌资产的 SHA256，供安装器与校验脚本使用；不保存 URL。改动时只需更新 `versions.json`。

### 7.1.1 补丁必须幂等应用（踩过的大坑）

`patch --forward` 对「已经打过」的补丁行为**不确定**：

| 情况 | `patch --forward` 的行为 |
|---|---|
| 完全匹配 | 报 `Reversed (or previously applied) patch detected` 并跳过（安全）|
| 带 fuzz / offset 匹配 | **可能把某些 hunk 再套一遍** → 源码出现重复声明 |

实际踩到过：上游的 `0001-termux-2x-port.patch` 在 `--keep-tree` 复用时被套了两次，
`packages/cli/script/build.ts` 里 `opentuiAliasPlugin` 声明了 3 次 → 编译直接失败：

```
error: "opentuiAliasPlugin" has already been declared
```

`build/build.sh` 里的解法（`apply_patch()` / `patch_applied()`）：

1. **先探测再应用**：先 `patch --dry-run -R` 试能否反向匹配，能反向 = 已应用 → 跳过。
2. **标记文件**：`$TREE/.opencode-build/applied-patches` 按 sha256 记录已应用的补丁。
3. **上游脚本按需调用**：只有当**所有**上游补丁都还没应用时，才调用
   `upstream/opencode-bionic/termux/ci/apply-patches.sh`（它是权威实现，冲突时响亮失败）；
   否则走幂等路径，绝不让它再 forward 一遍。

> 同理，`build/overrides/` 是**整树覆盖**语义：目录层级原样映射到构建树。
> `build/overrides/packages/app/vite-build.mjs` → `$TREE/packages/app/vite-build.mjs`。
> **平铺存放会落到 `$TREE/vite-build.mjs`**，构建时就找不到它了
> （`Error: Cannot find module '.../packages/app/vite-build.mjs'`）。

### 7.2 `build/verify.sh`（7 步）
```
1  SHA256 与 artifact/opencode.sha256 一致
2  ELF64 / AArch64 / DYN / 解释器 = /system/bin/linker64 / NEEDED 只含 Bionic
3  GLIBC_ 版本符号数 = 0
4  内嵌 ELF 逐个扫描 + 关键资产 sha256 比对
5  实机 --version
6  Web UI：根路径 200 + 全部入口 assets 200
7  功能点抽查：产物内含 enterBehavior 逻辑 + 中文「回车发送」
```

### 7.3 判定 glibc 的正确姿势（踩过的坑）

> ❌ **不要**用「全文件 `grep -a 'libc.so.6'`」来判断。
> Bun 运行时**自己的字符串表**里就有一堆 glibc 字面量 —— 例如产物偏移 66 135 224 处的
> `libc.so.6`，夹在 `"UTF-16"`、`"randomUUIDv5"`、`"fts5"`、`"content-md5"` 之间。
> 那是数据，不是依赖，会误报。`libutil.so.1` 同理（在 66 145 657）。
>
> ✅ **权威判据**（`build/scan-elf.ts` 就是这么做的）：
> 1. `readelf -d` 的 `NEEDED` 列表（主程序 + 每个内嵌 ELF）
> 2. `readelf -V` 的 `GLIBC_` 版本符号数
> 3. 每个内嵌 ELF 切片的**原始字节**里没有 glibc SONAME
> 4. `NEEDED` 为空的**完全静态** ELF 里出现 `ld-musl` 之类的字面量是正常的
>    （Rust/musl 工具链静态产物的残留字面量），不算依赖

### 7.4 `build/scan-elf.ts`
自己写的内嵌 ELF 扫描器：从二进制里找出所有 `\x7fELF` magic，
按 ELF 头算出切片边界，切出来单独 `readelf -d` 看 `NEEDED`，
并输出每片的 sha256。支持 `--json` 和 `--expect <sha256>:<label>`。

> 实现上踩过两个坑，注释里都写了：
> 1. `ePhoff` / `eShoff` 是**相对 ELF 头起点**的偏移，计算切片长度时**必须加上基址 `off`**。
> 2. 不能用「解析完就 `i += size`」推进游标 —— 主程序的 size 就是整个文件，
>    那样会把后面内嵌的 `.so` 全部跳过。必须**逐个 magic 位置独立解析**。

---

## 8. 安装器 `opencode-termux.sh`

> 设计文档见 `docs/INSTALLER.md`；架构视角见 `docs/ARCHITECTURE.md` §2。

### 8.1 命令
```bash
bash opencode-termux.sh                 # 交互菜单
bash opencode-termux.sh install  [路径]  # 全新安装
bash opencode-termux.sh reinstall [路径] # 卸载重装（y/N 确认）
bash opencode-termux.sh uninstall        # 卸载（y/N 确认）
bash opencode-termux.sh doctor           # 只读诊断
bash opencode-termux.sh help             # 帮助
```

`路径` 可为 **ELF 文件** 或 **目录**；省略时在当前目录按文件名搜索。

### 8.2 固定流水线（两种模式）

严格串行，每一步确认正常才进下一步；任一失败立即 `exit`：

```
[1/5] 环境检测        PREFIX / aarch64 / linker64 / HOME 可写
[2/5] 定位 ELF        指定文件 · 指定目录 · 按文件名搜索
[3/5] 哈希校验        ★ 硬闸门：不匹配 → 终止（exit 1），零改动
[4/5] 权限            chmod 700（仅在哈希通过后）
[5/5] 依赖检测与安装   pkg update → 逐个 pkg install 缺失项
      ↓ 全部成功后
      部署 ELF → 注册命令
```

- **全新安装**：如上顺序。
- **卸载重装**：`… 校验 → 权限 →` **卸载** `→ 依赖 → 部署`。
  先定位并校验，确保「确实有可装的东西」再执行破坏性卸载 ——
  否则万一新 ELF 哈希不对，设备会处于无可用程序的状态。

### 8.3 安装布局
```
$HOME/.local/share/opencode/opencode        # ELF 本体（真实文件，700）
$HOME/opencode/bin/{opencode,oc,ocs,ocp,ocsp,ocrun,ocpair,ocmodels,ocdoctor}
$PREFIX/bin/<name>                          # 全部为软链 → 上面的启动脚本
```
卸载只移除上表内容；**保留**会话数据库（`opencode.db*`）、配置、缓存、状态。

### 8.4 注册的命令
| 命令 | 作用 |
|---|---|
| `opencode` | 主入口 |
| `oc` | 等价 opencode |
| `ocs` | `serve`（免密，默认 4096）|
| `ocp` | `serve --password`（带密码）|
| `ocsp` | `serve --password`（带密码）|
| `ocrun` | `run` 一次性执行 |
| `ocpair` | `pair` 打印配对链接 |
| `ocmodels` | `models` 列出模型 |
| `ocdoctor` | 执行本安装器的 `doctor` |

### 8.5 校验
- 哈希：与内置 `EXPECTED_SHA256` 严格比对，**不匹配即终止**。
- ELF 头：定位阶段做 ELF magic 校验（`greadelf`/`readelf`，或回退读 `7f454c46`）。
- 不做「实机 `--version`」运行测试，也不做原子切换（无多版本）。 

### 8.6 依赖（全为 Termux Bionic 包）
`curl jq git ripgrep coreutils util-linux tar xz-utils zstd termux-tools binutils ca-certificates`
缺失时 `pkg update` + `pkg install` 自动安装（`ca-certificates` 以
`$PREFIX/etc/tls/cert.pem` 是否存在判定）。

### 8.7 安全设计
- **哈希闸门在最前**：通过之前不做 chmod、不复制、不卸载。
- ELF 本体用真实路径（不用软链），避免 `process.execPath` / `argv[0]` 受影响。
- 卸载仅限本安装器创建的命令与 ELF；用户数据一律保留。
- `umask 077`；`set -Eeuo pipefail`。

### 8.8 已知行为
- `reinstall` 会先 `y/N` 确认，再走完整流水线。
- 输入非 `y` 即取消，不做任何改动。
- 依赖安装失败会终止，**不进入部署阶段**。

### 8.9 【预留】从 Git 拉取新文件 + 校验
脚本中已留占位函数 `fetch_from_git()`（调用点尚未接入）。
完整设计流程、接口约定、信任锚与待定问题见 `docs/INSTALLER.md` §5。

---

## 9. 版本与来源

- 上游仓库：`anomalyco/opencode`，跟踪分支 `dev`
- 上游提交（**完整 sha**）：`4d5965762ec5e0d1a0b14630553fc62b51a11fba`（2026-10-21）
- 社区构建器：`bd-loser/opencode-bionic`（vendored 在 `upstream/opencode-bionic/`）
- 产物版本：`v2.1.2-dev`（`OPENCODE_VERSION` 让 `versions.ts` 跳过版本改写）
- 产物 sha256：`25cde8a86433852d9e981efde4ee5c1a477dee96bf483d5e14469a0433edb50e`
  （每次构建都会变，见 §1 的说明；`artifact/opencode.sha256` 里是当前这份的。
  历史另一次构建为 `eeb2d52b…c5e1553`，内嵌资产两次一致）

Bionic 资产来源（**必须钉版本**，`latest` 指向 404）：

| 资产 | URL |
|---|---|
| bun-pty Bionic `.so` | `…/bun-termux/releases/download/bun-pty-v0.4.11/librust_pty_arm64_bionic.so` |
| opencode-pty 守护进程 | `…/bun-termux/releases/download/opencode-pty-v0.2.0/opencode-pty-android-aarch64` |
| bun 1.4.3-patched | `…/bun-termux/releases/download/v1.4.3-patched/bun_1.4.3-patched_aarch64.deb` |

sha256 记录在 `env.sh`（`OPENCODE_BUN_PTY_SHA256` / `OPENCODE_PTY_SERVICE_SHA256`），
`build/verify.sh` 第 4 步用 `--expect` 强制比对。

---

## 10. 环境信息（实测）

```
uname -m           aarch64
Android            16 / API 36
PREFIX             /data/data/com.termux/files/usr
bun                /data/data/com.termux/files/usr/lib/bun-termux/bun (1.4.3-canary.1)
node               v26.4.0
readelf            greadelf（binutils 2.46+ 把 readelf 改名）
磁盘可用           ~89G
```

无 python。`/tmp` 不可写 → 临时文件放 `~`。`bun` 需 `export PATH="$PREFIX/bin:$PATH"`。

---

## 11. 注意事项 / 坑

1. **不要**用 `bun run build` 跑 vite，**不要**用异步 `brotliCompress`/`readdir`（会卡死，见第 4 节）。
2. **不要**用全文件 `grep 'libc.so.6'` 判 glibc（见 7.3）。
3. `/tmp` 在 Termux **不可写**，临时文件放 `~`。
4. 构建/长任务用**前台单任务**；不要并发。
5. `bun` 的 `$` shell 在 import effect 的进程里**不可靠**，改用 `spawnSync`。
6. `git fetch` 上游**必须用完整 sha**，短 sha 会失败。
7. 上游无 v2 稳定版，版本号含 `-dev`，属预发布，可能不稳定。
8. 更新前请退出 OpenCode / 网页版。
9. TypeScript 7（原生预览版）没有 `@typescript/typescript-android-arm64` 平台包，
   Termux 上跑不了 `tsc -b`；改用根 `node_modules/typescript/bin/tsc6`（TS 6.0.2，纯 JS）。
10. app 单测的 `jsxDEV` 报错是**既有环境问题**（solid-js dev build 解析），
    stash 掉改动后同样失败，与本次改动无关；非 JSX 测试可正常通过。

---

## 12. 待办

- [ ] **从 Git 拉取新文件 + 校验**（用户后续需要）：
      设计流程与接口约定已写在 `docs/INSTALLER.md` §5，脚本里留了占位函数 `fetch_from_git()`。
      实现要点：拉取产物 + 清单 → 用内置 `EXPECTED_SHA256` 核对清单未被篡改（信任锚）→
      走现有哈希闸门 → 再部署。倾向只拉 Release 资产（191 MB 二进制不宜进 git）。
- [x] 构建树整理成可复现状态 —— 4 份补丁（含新固化的 `0004`）加到干净上游 clone 后
      与构建树逐字节一致；对应补丁在 `build/patches/`。
- [ ] 长期跟上游 dev 分支（`4d5965762ec5e0d1a0b14630553fc62b51a11fba` 之后还有新提交）。
      上游漂移时 `build/build.sh` 第 2/3 步会响亮失败，按上游
      `termux/ci/refresh-patches.sh` 重新生成补丁即可。

---

## 13. 交付内容说明

本包包含：

- `artifact/` —— 编译产物二进制 + 校验和（二进制走 GitHub Release 附件，见 `docs/PUBLISHING.md`）
- `installer/` —— 安装器成品
- `build/` —— 本包自有的补丁、覆盖文件、构建/校验脚本
- `upstream/opencode-bionic/` —— 第三方构建器（termux 脚本 + 补丁；158 KB，构建必需输入）
- `docs/` —— 本项目文档（**随仓库发布**）

**未包含**（体积过大，可另行拷贝）：

- `~/src/build-tree/node_modules`（约 2.9G，可由 `bun install` 重建）
- `~/src/build-tree/.git`

重建构建树：`bash build/build.sh`（需网络，会重新拉上游）。
