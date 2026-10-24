# 常见故障与处置

> 配套：`docs/HANDOVER.md`（主交接文档）。以下每条都是本项目**实际踩过**的。
> 涉及安装行为的条目（§8、§12）已对齐当前的串行安装器。

---

## 1. `dlopen failed: library "libc.so.6" not found`

**症状**
```
Error: dlopen failed: library "libc.so.6" not found: cannot open shared object file
    at <anonymous> (…/bun-pty@0.4.11/node_modules/bun-pty/src/terminal.ts:120:8)
```

**根因**
npm 上 `bun-pty@0.4.11` 发布的预编译 `librust_pty_arm64.so` 是 **glibc 链接**的
（`NEEDED: libc.so.6 libpthread.so.0 libdl.so.2 libutil.so.1`）。
`bun-pty/src/terminal.ts` 在**模块顶层**就 `dlopen` 它 —— 只要 import bun-pty 就会触发。

**处置**（不是运行时兼容层，是**用 Bionic 版重新构建**）
```bash
# 1) 用 Bionic 版覆盖构建树里那份
curl -fsSL -o \
  ~/src/build-tree/node_modules/.bun/bun-pty@0.4.11/node_modules/bun-pty/rust-pty/target/release/librust_pty_arm64.so \
  https://github.com/bd-loser/bun-termux/releases/download/bun-pty-v0.4.11/librust_pty_arm64_bionic.so

# 2) 确认是 Bionic（不该命中 libc.so.6）
grep -qa 'libc.so.6' <上面那个文件> && echo "还是 glibc！" || echo "OK"

# 3) 重建
bash build/build.sh

# 4) 核对产物里内嵌的确实换了
bun build/scan-elf.ts artifact/opencode \
  --expect 179b2b30748d73167898397a5f51388d9d5645b94504c8d092e7ede0efac0b0c:bun-pty
```

> `build/build.sh` 第 6 步已经自动化了这件事，不用手动。

---

## 2. 构建跑到「`✓ built in …s`」之后卡死不退出

**根因**
构建流程 `import "effect"`。在 Termux/Bionic 下，**Bun 一旦加载 effect，其异步线程池就不再 drain**。
表现为三个不同的卡死点：shell promise 等不到子进程、vite 的 `build()` promise 永不 resolve、
异步 `readdir` / `brotliCompress` 永久挂起（CPU 0%）。

**处置**（**不可回退**）
| 位置 | 改法 |
|---|---|
| `packages/cli/script/app-assets.ts` | `` $`bun run build` `` → `spawnSync("node", ["vite-build.mjs"])` |
| `packages/cli/script/app-assets.ts` | `brotliCompress` → `brotliCompressSync`；`readFile` → `readFileSync` |
| `packages/cli/script/files.ts` | `readdir`（promises）→ `readdirSync` |
| `packages/app/vite-build.mjs` | vite `build()` API + `closeBundle` 钩子内 `process.exit(0)` |

对应本包补丁 `build/patches/0001-bionic-build-harness.patch` 与
整树覆盖 `build/overrides/packages/app/vite-build.mjs`（→ `$TREE/packages/app/vite-build.mjs`）。

**验证元凶**（会卡住）
```bash
cd ~/src/build-tree
printf 'import { $ } from "bun"\nimport "effect"\nawait $`node node_modules/vite/bin/vite.js build`.cwd("packages/app")\n' > t.ts
bun t.ts
```

---

## 2b. 构建报 `Cannot find module '.../packages/app/vite-build.mjs'`

**根因**
`build/overrides/` 是**整树覆盖**语义：目录层级原样映射到构建树。
如果 `vite-build.mjs` 平铺放在 `build/overrides/` 根下，会被拷到 `$TREE/vite-build.mjs`，
而构建脚本要的是 `$TREE/packages/app/vite-build.mjs`。

**处置**
把文件放到正确的层级：
```
build/overrides/packages/app/vite-build.mjs   ← 正确
build/overrides/vite-build.mjs                 ← 错误
```

---

## 2c. 构建报 `error: "opentuiAliasPlugin" has already been declared`

**根因**
补丁被**重复应用**了。`patch --forward` 对「已经打过」的补丁行为不确定：
带 fuzz / offset 匹配时，它可能把某些 hunk 再套一遍，导致源码里出现重复声明。
`--keep-tree` 复用构建树时最容易踩到。

**处置**
`build/build.sh` 已内置幂等应用器（先反向 dry-run 探测 → 再决定是否应用，
并用 `$TREE/.opencode-build/applied-patches` 记录）。若手工操作，先确认：
```bash
cd ~/src/build-tree
git checkout -- packages/cli/script/build.ts     # 恢复被重复应用的 hunk
rm -f packages/cli/script/*.rej
```

> 判据：`grep -c 'opentuiAliasPlugin' packages/cli/script/build.ts` 应该只有 1 处声明。
> `build/build.sh` 的幂等应用器会先探测再应用，正常不会走到这里。

---

## 3. 产物里 grep 到 `libc.so.6`，但 `readelf -d` 又是干净的

**这是误报**，不用管。

Bun 运行时**自己的字符串表**里就有一堆 glibc 字面量。产物里：
- `libc.so.6` @ 66 135 224（夹在 `"UTF-16"` / `"randomUUIDv5"` / `"fts5"` / `"content-md5"` 之间）
- `libutil.so.1` @ 66 145 657

**正确判据**：
1. `readelf -d` 的 `NEEDED`
2. `readelf -V` 的 `GLIBC_` 版本符号
3. 逐个内嵌 ELF 切片的原始字节
4. `NEEDED` 为空的**完全静态** ELF 里出现 `ld-musl` 等字面量是正常残留（Rust/musl 工具链产物），不算依赖

`build/scan-elf.ts` 已按这个逻辑实现，`build/verify.sh` 第 3/4 步用它。

---

## 4. 回车行为设置选了没反应

**根因**
老实现读的是 `(props.controller as any).settings`，但 `createComposerEditor()` 返回的对象
**没有 `settings` 键** → 恒为 `undefined` → `?? "send"` 永远生效 → **静默失效**。

**处置**：走 **`view` 通道**（`ComposerEditorView.enterBehavior?: Accessor<"send"|"newline">`），
不要动 controller 的内部结构。
完整清单见 `docs/HANDOVER.md` 第 6 节。

> 不要用 `use()` 拿设置：`use()` 在没有 provider 时会抛错，
> 而 `composer.stories.tsx` 用的是手写 mock，不会调 `createComposerModel`。

---

## 5. `tsc -b` 报 `Unable to resolve @typescript/typescript-android-arm64`

**根因**
TypeScript 7（原生预览版）需要平台专属的原生包，**没有 Android 版本**。

**处置**
用根目录的 TypeScript 6（纯 JS）：
```bash
cd ~/src/build-tree/packages/app
node ../../node_modules/typescript/bin/tsc6 -b --pretty false
```

---

## 6. app 单测报 `SyntaxError: Export named 'jsxDEV' not found`

**这是既有环境问题，与业务改动无关。**
在 Termux 上用 bun 跑 solid-js 的 dev build 解析失败。stash 掉全部改动后同样失败。

非 JSX 的测试可正常通过：
```bash
cd ~/src/build-tree/packages/app
bun test --conditions=solid --preload ./happydom.ts src/composer/editor/actions.test.ts   # ✔ 4 pass
```

---

## 7. `git fetch` 上游报 `couldn't find remote ref <短 sha>`

**根因**
GitHub 的 `uploadpack.allowReachableSHA1InWant` 不允许按短 sha fetch。

**处置**：用**完整 40 位 sha**
```bash
git fetch --depth 1 origin 4d5965762ec5e0d1a0b14630553fc62b51a11fba
```
`env.sh` 里的 `OPENCODE_UPSTREAM_REF` 已经是完整 sha。

---

## 8. 安装器说「未找到 opencode」

**根因**
没给路径时，安装器只在**当前目录**按文件名搜索（`opencode` / `opencode-linux-arm64`，
以及 `artifact/`、`bin/`、`../artifact/` 子路径），再退回 `find -maxdepth 5`。
若 ELF 不在这些位置，就会报「未找到」。

**处置**：显式指定目录或文件即可（路径可为目录，也可为 ELF 文件本身，推荐用相对当前目录的路径）：
```bash
bash opencode-termux.sh install ./artifact
bash opencode-termux.sh install ./opencode
```
定位规则详见 `docs/ARCHITECTURE.md` §2.3 与 `docs/INSTALLER.md` §3.3。

---

## 9. `sha256sum -c artifact/opencode.sha256` 报 `No such file or directory`

**根因**
`sha256sum -c` 按 **当前工作目录**解析文件名，不是相对校验和文件所在目录。

**处置**：在**包根**执行：
```bash
cd <包根>
sha256sum -c artifact/opencode.sha256     # → artifact/opencode: OK
```

---

## 10. 构建报 `No space left on device`

**处置**
```bash
df -h ~                     # 看可用空间
rm -rf ~/src/build-tree     # 构建树可重建（~2.9G）
```
`build/build.sh` 默认会清空构建树重建；只想重跑补丁+构建用 `--keep-tree`。

---

## 11. `/tmp` 不可写

Termux 的 `/tmp` 不可写。所有临时文件放 `~`：
```bash
LOG="$HOME/.opencode-verify.XXXXXX.log"
```

---

## 12. 诊断清单

```bash
# 1) 环境
uname -m; echo $PREFIX; bun --version; node --version; command -v greadelf

# 2) 产物静态
bash build/verify.sh

# 3) 安装状态（安装器只读诊断；也可直接用 ocdoctor）
bash opencode-termux.sh doctor

# 4) Web UI
opencode serve --port 40999 &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:40999/

# 5) PTY
cd ~/src/build-tree/packages/core
bun -e 'const {spawn}=await import("bun-pty");
           const p=spawn("/system/bin/sh",["-c","echo OK; tty"],{cols:80,rows:24});
           let o=""; p.onData(d=>o+=d);
           setTimeout(()=>{console.log(o.trim());process.exit(0)},1500)'
```
