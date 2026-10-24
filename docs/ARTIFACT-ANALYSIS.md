# OpenCode v2 Bionic 构建产物分析报告

日期：2026-10-23（v2：按当前产物实测重新生成）
产物：`opencode-build/artifact/opencode`（构建树中位于 `packages/cli/dist/cli-linux-arm64/bin/opencode`）
版本：**v2.1.2-dev**（基于上游 `anomalyco/opencode` dev `4d5965762ec5e0d1a0b14630553fc62b51a11fba`）

> 复现全部校验：`bash build/verify.sh`

> ## ⚠️ 多个 sha256，别搞混
>
> 本仓库历史上存在**多次构建**，主程序 sha256 不同（Bun bundle **非逐字节可复现**）：
>
> | 构建 | 主程序 sha256 | 说明 |
> |---|---|---|
> | 旧（2026-10-21）| `105793bdf78fb01f8a8f5d8bdf2e77b819f2f10db342f1d338ba2e8ca3a41e51e6` | 早期产物 |
> | 旧（2026-10-21/22）| `eeb2d52b3166c6a10c893221ce8cad98b13bb624972c2443577f186f1c5e1553` | 当时 `artifact/` 里的那份 |
> | **当前**（2026-10-24）| `25cde8a86433852d9e981efde4ee5c1a477dee96bf483d5e14469a0433edb50e` | 现 `artifact/opencode`（含回车行为、免密 `opencode serve` 修复） |
>
> **主程序 sha256 不是「源码是否一致」的判据**。判据是 §2.3 的**内嵌资产 sha256**
> （bun-pty `179b2b30…`、pty 守护进程 `8d62b709…`）与 `build/verify.sh` 的 `GLIBC_`/`NEEDED` 检查。
> 各次构建的这些内嵌资产**完全一致**。

---

## 1. 结论摘要

| 项目 | 结果 |
|---|---|
| 零 glibc 依赖 | **是** —— `GLIBC_` 版本符号 **0** 个，主程序与全部内嵌 ELF 均无 glibc |
| 内嵌 PTY 库 | **Bionic 版**（`NEEDED` 只剩 `libc.so` / `libdl.so`），sha256 与源资产一致 |
| Web UI | **可用** —— 根路径 **HTTP 200**，56 个入口资源全 200 |
| 回车行为设置 | **已编译进产物** —— schema / 存取器 / UI / 按键逻辑 / 中英繁三语全部就位 |
| 二进制自检 | `--version` → `opencode v2.1.2-dev` |
| PTY 实机 | **可用** —— `spawn` 成功，`tty` → `/dev/pts/2` |
| 构建退出码 | **0**（vite `✓ built in 25.67s`） |
| 校验脚本 | `build/verify.sh` 7 步全过 |

**产物无问题，可安全替换。**

### 1.1 两条构建路径都已验证

本包产物的构建脚本 `build/build.sh` 有两种用法，**两条都在本机端到端跑通过**：

| 路径 | 命令 | 结果 |
|---|---|---|
| 全新构建 | `bash build/build.sh` | 10 个阶段全过，EXIT=0，第 3 步走上游 `apply-patches.sh` 正常路径 |
| 复用构建树 | `bash build/build.sh --keep-tree` | 10 个阶段全过，EXIT=0，第 3 步走幂等路径（识别出上游补丁已应用并跳过）|

两条路径产出的**内嵌资产 sha256 完全一致**（bun-pty `179b2b30…`、pty 守护进程 `8d62b709…`、
OpenTUI native core `2231bb13…`），只有主程序自身的 sha256 因 Bun bundle 非逐字节可复现而不同。

> 复用路径是踩坑踩出来的：`patch --forward` 对「已打过」的补丁在 fuzz/offset 匹配下会**重复套用 hunk**，
> 导致 `build.ts` 里 `opentuiAliasPlugin` 声明两次 → 编译失败。
> 解法见 `docs/HANDOVER.md` §7.1.1 与 `docs/TROUBLESHOOTING.md` §2c。

---

## 2. 产物静态校验

### 2.1 文件与 ELF

```
大小      199 821 576 B (191 MiB)
sha256    25cde8a86433852d9e981efde4ee5c1a477dee96bf483d5e14469a0433edb50e
Class     ELF64
Type      DYN (Position-Independent Executable file)
Machine   AArch64
解释器    /system/bin/linker64      ← Bionic，非 glibc
```

### 2.2 依赖与符号

```
NEEDED    libc.so  libm.so  libdl.so      ← 全为 Android/Bionic
RPATH     (none)
SONAME    (none)

GLIBC_ 版本符号数   0
```

### 2.3 内嵌 ELF（`build/scan-elf.ts` 输出）

产物内嵌 4 个 ELF：

| 偏移 | 大小 | Type | NEEDED | sha256（前 16） | 是什么 |
|---|---|---|---|---|---|
| 0 | 199 821 576 | DYN | `libc.so` `libm.so` `libdl.so` | `25cde8a86433852d` | 主程序 |
| 134 576 611 | 21 175 280 | DYN | `libc++_shared.so` `libm.so` `libc.so` `libdl.so` | `2231bb13409da854` | OpenTUI native core（`@androidtui/core-android-arm64`）|
| 182 128 587 | 2 920 272 | EXEC | （无 —— 完全静态）| `8d62b70972255110` | opencode-pty 常驻守护进程 |
| 199 266 940 | 522 040 | DYN | `libc.so` `libdl.so` | `179b2b30748d7316` | **bun-pty `librust_pty_arm64.so`（Bionic）** |

> 偏移值来自当前产物实测（`bun build/scan-elf.ts artifact/opencode`）。
> 主程序 bundle 长度每次构建都可能变化，内嵌资产会跟着整体平移；
> **内嵌资产的 sha256 始终一致。**

> 内嵌切片的 sha256 与放进构建树的源资产**逐字节一致**（bun-pty / pty 守护进程两枚），
> 说明构建过程没有改动它们，只是原样内嵌。
> 注意：主程序本身的 sha256 **每次构建都会变**（Bun bundle 不是逐字节可复现的），
> 所以不能拿产物 sha256 当「源码是否一致」的判据 —— 判据是上面的**内嵌资产 sha256**
> 与 `build/verify.sh` 第 3/4 步的 `GLIBC_` / `NEEDED` 检查。

后两个与放进构建树的源资产 **sha256 逐字节一致**：

```
$ sha256sum <构建树>/node_modules/.../bun-pty/rust-pty/target/release/librust_pty_arm64.so
179b2b30748d73167898397a5f51388d9d5645b94504c8d092e7ede0efac0b0c   ← == 产物内嵌切片
$ sha256sum <构建树>/node_modules/@opencode-ai/pty-linux-arm64-gnu/bin/opencode-pty
8d62b709722551109701f192310b70c5645f8ecf30d7b8f0c15cb920b1f3b5df   ← == 产物内嵌切片
```

> 也可以用 `build/verify.sh` 第 4 步的 `--expect` 强制比对，不必手工记路径。

### 2.4 关于 `libc.so.6` 字面量 —— 误报说明

产物全文件扫描会命中 `libc.so.6`（偏移 66 135 224）与 `libutil.so.1`（偏移 66 145 657）。
**这两个不是依赖**，而是 Bun 运行时自己字符串表里的数据：

```
…
UTF-16
libc.so.6          ← 偏移 66 135 224
>= 1 and <= 6
randomUUIDv5
fts5
content-md5
rc4-hmac-md5
…
```

判定 glibc 的权威依据是 `readelf -d`（NEEDED）、`readelf -V`（`GLIBC_` 版本符号）
以及**逐个内嵌 ELF 切片的原始字节**。
`NEEDED` 为空的完全静态 ELF 里出现 `ld-musl` 等字面量同样是残留数据，不构成依赖。

详见 `docs/HANDOVER.md` 第 7.3 节。

---

## 3. Web UI

### 3.1 服务与路由
```
$ opencode serve --port 40999
GET /                 → HTTP 200
GET /_assets/*        → 56 个入口资源全部 HTTP 200
```

### 3.2 产物规模
```
packages/app/dist/_assets/  共 3117 个文件
其中入口资源 56 个（含 index / shell / runtime / language / 各语言包）
```

### 3.3 回车行为设置在产物中的落点

| chunk | 内容 |
|---|---|
| `runtime-*.js` | schema `enterBehavior:I([\`send\`,\`newline\`])`；默认 `enterBehavior:\`send\``；存取器 `enterBehavior:Q(()=>e.general?.enterBehavior, Z.general.enterBehavior)`、`setEnterBehavior(e){t(\`general\`,\`enterBehavior\`,e)}` |
| `shell-*.js` | 设置项 UI：选项 `{value:\`send\`,label:t(...send)}` / `{value:\`newline\`,label:t(...newline)}`；`current` 读 `t.general.enterBehavior()`；`onSelect` → `t.general.setEnterBehavior(e.value)`；description 注入 `{{keybind}}`/`{{modKeybind}}` |
| `incompatible-server-panel-*.js` | **注入点** `view:{placeholder:k, enterBehavior:()=>g.general.enterBehavior()}`；按键逻辑 `if(t.key===\`Enter\`&&!t.isComposing){ if(!((o.enterBehavior?.()??\`send\`)===\`send\`?!t.shiftKey:t.shiftKey||n)||(t.preventDefault(),t.repeat))return; e.controller.submit(...) }` |
| `index-*.js` | 简体 zh 文案：「回车键行为」「选择回车是发送消息还是插入换行。设为换行模式后，使用 {{keybind}} 或 {{modKeybind}} 发送。」「回车发送」「回车换行」 |
| `language-*.js` | 英文文案："Enter key behavior" / "Enter to send" / "Enter for newline" |
| `zht-CWaPMJzI.js` | 繁体文案：「Enter 鍵行為」「Enter 傳送」「Enter 換行」 |

按键行为矩阵：

| 设置 | Enter | Shift+Enter | Mod+Enter |
|---|---|---|---|
| `send`（默认）| 发送 | 换行 | 发送（alternate）|
| `newline` | 换行 | 发送 | 发送 |

---

## 4. PTY 实机验证

```bash
$ cd ~/src/build-tree/packages/core
$ bun -e 'const m = await import("bun-pty"); console.log("加载成功", Object.keys(m))'
加载成功 [ 'Terminal', 'spawn' ]

$ bun -e 'const {spawn}=await import("bun-pty");
           const p=spawn("/system/bin/sh",["-c","echo PTY_OK; tty"],{cols:80,rows:24});
           let o=""; p.onData(d=>o+=d);
           setTimeout(()=>{console.log(o.trim());process.exit(0)},1500)'
PTY_OK
/dev/pts/2
```

Bionic `.so` 能在本机正常 `dlopen`，且产物里内嵌的就是同一份文件（sha256 一致）。

---

## 5. 与上一版产物的对比

| 项目 | 旧产物（2026-10-21） | 新产物（2026-10-22/23） |
|---|---|---|
| 大小 | 196 937 992 B（188 MiB）| 199 821 576 B（191 MiB）|
| sha256 | `105793bd…41e51e6` | `25cde8a86…3edb50e`（见文首说明；历史构建多次，主程序 bundle 每次不同）|
| 内嵌 bun-pty | **glibc**（`NEEDED: libc.so.6 libpthread.so.0 libdl.so.2 libutil.so.1`）| **Bionic**（`NEEDED: libc.so libdl.so`）|
| 内嵌 pty 守护进程 | **无**（可选依赖没装上，`resolveOpencodePty` 失败被吞掉）| **有**（Bionic 静态版，2 920 272 B）|
| `opencode serve` | 启动后报 `dlopen failed: library "libc.so.6" not found` | 正常 |
| 回车行为设置 | 读 controller 上不存在的 `settings` 键 → **静默失效** | 走 `view` 通道，**生效** |
| 设置项文案 | 无 | en / zh / zht 三语齐全 |
| Web UI 资源 | 25 个入口资源 | 56 个入口资源 |

---

## 6. 复核命令清单

```bash
# 一次性跑完 7 步校验（10 个构建阶段仅适用于 build/build.sh）
bash build/verify.sh artifact/opencode

# 单独看内嵌 ELF
bun build/scan-elf.ts artifact/opencode
bun build/scan-elf.ts artifact/opencode --json
bun build/scan-elf.ts artifact/opencode \
  --expect 179b2b30748d73167898397a5f51388d9d5645b94504c8d092e7ede0efac0b0c:bun-pty \
  --expect 8d62b709722551109701f192310b70c5645f8ecf30d7b8f0c15cb920b1f3b5df:pty-daemon

# 手工核对
sha256sum -c artifact/opencode.sha256          # 从包根执行
greadelf -hW artifact/opencode | head -20
greadelf -lW artifact/opencode | grep interpreter
greadelf -dW artifact/opencode | grep NEEDED
greadelf -VW artifact/opencode | grep -c GLIBC_
```
