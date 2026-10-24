# 目录架构与安装流程

> 本文档说明本包的目录职责、路径真源，以及 `opencode-termux.sh` 的安装流程。
> 所有内容均按**当前实际状态**编写（安装器已按「固定串行流水线、不做历史回滚」重写）。

## 1. 整体目录架构

本包遵循「每个目录只有一个职责」的原则。`env.sh` 是全包唯一路径真源。

```text
opencode-build/                      # 包根（OPENCODE_BUILD_ROOT）
├── README.md                        # 入口文档（GitHub 仓库首页）
├── env.sh                           # ★ 路径唯一真源
│
├── artifact/                        # 【成品】可直接安装的产物
│   ├── opencode                     #   v2.1.2-dev Bionic ELF（aarch64，191 MiB）
│   │                                #   注：不进 git，走 Release 附件（见 docs/PUBLISHING.md）
│   └── opencode.sha256              #   包根相对路径校验和（sha256sum -c 直接可用）
│
├── installer/                       # 【成品】安装器
│   └── opencode-termux.sh           #   定位 / 校验 / 依赖 / 菜单（全新安装 · 卸载重装）
│
├── build/                           # 【源】本项目自有改动与构建脚本
│   ├── build.sh                     #   一键构建（10 个阶段：0～9）
│   ├── verify.sh                    #   产物校验（7 步）
│   ├── package-release.sh           #   生成 Release 离线包
│   ├── scan-elf.ts                  #   内嵌 ELF 扫描器（bun/node 均可跑）
│   ├── patches/                     #   本包补丁（在第三方补丁之后应用）
│   │   ├── 0001-bionic-build-harness.patch
│   │   ├── 0002-app-enter-behavior.patch
│   │   ├── 0003-app-enter-behavior-i18n.patch
│   │   └── 0004-cli-serve-no-password.patch
│   └── overrides/                   #   整树覆盖（目录层级原样映射到构建树）
│       └── packages/app/vite-build.mjs
│
├── upstream/                        # 【第三方】原样 vendored，不做修改
│   └── opencode-bionic/             #   社区 Bionic 构建器（build.sh 必需输入）
│       ├── versions.json            #   ★ Bionic 资产版本与 URL 唯一真源
│       ├── termux/                  #   config delta、补丁脚本、上游补丁
│       ├── install.sh               #   上游参考脚本
│       └── repo-setup.sh
│
└── docs/                            # 【文档】随仓库发布
    ├── HANDOVER.md                  #   主交接文档
    ├── CHANGES.md                   #   改动清单（逐文件）
    ├── INSTALLER.md                 #   安装器设计（流程 / 布局 / git 拉取预留）
    ├── ARCHITECTURE.md              #   本文档
    ├── ARTIFACT-ANALYSIS.md         #   产物分析
    ├── PUBLISHING.md                #   GitHub 发布说明
    └── TROUBLESHOOTING.md           #   常见故障与处置
```

### 1.1 路径真源（`env.sh`）

构建/校验脚本都通过 `source env.sh` 取路径，**不硬编码** `$HOME/...`。
安装器是独立分发文件，不 source `env.sh`，但其内置安装路径必须与本节口径一致。

| 变量 | 用途 | 默认值 |
|---|---|---|
| `OPENCODE_BUILD_ROOT` | 包根目录（自动推断） | 本文件所在目录 |
| `OPENCODE_BUILD_ARTIFACT_DIR` | 成品目录 | `$OPENCODE_BUILD_ROOT/artifact` |
| `OPENCODE_BUILD_INSTALLER_DIR` | 安装器目录 | `$OPENCODE_BUILD_ROOT/installer` |
| `OPENCODE_BUILD_BUILD_DIR` | 构建脚本目录 | `$OPENCODE_BUILD_ROOT/build` |
| `OPENCODE_BUILD_DOCS_DIR` | 文档目录 | `$OPENCODE_BUILD_ROOT/docs` |
| `OPENCODE_BUILD_UPSTREAM_DIR` | 第三方构建器 | `$OPENCODE_BUILD_ROOT/upstream/opencode-bionic` |
| `OPENCODE_BUILD_ARTIFACT` | 产物路径 | `$OPENCODE_BUILD_ARTIFACT_DIR/opencode` |
| `OPENCODE_BUILD_ARTIFACT_SHA256` | 校验和路径 | `$OPENCODE_BUILD_ARTIFACT_DIR/opencode.sha256` |
| `OPENCODE_INSTALL_ROOT` | 安装根目录 | `$HOME/opencode` |
| `OPENCODE_BUILD_TREE` | 上游构建树（包外，避免污染交付物） | `$HOME/src/build-tree` |
| `OPENCODE_BUILD_DIST_BIN` | 构建产物路径 | `$OPENCODE_BUILD_TREE/packages/cli/dist/cli-linux-arm64/bin/opencode` |
| `OPENCODE_BUN_PTY_SHA256` / `OPENCODE_PTY_SERVICE_SHA256` | 嵌入资产 sha256（与 `versions.json` 同步） | 固定值 |
| `OPENCODE_VERSION` / `OPENCODE_CHANNEL` / `OPENCODE_UPSTREAM_REF` | 元信息 | `2.1.2-dev` / `dev` / `4d596576…` |

`opencode_artifact_candidates()` 定义**构建侧脚本共用**的查找顺序（`build/verify.sh` 等）：

```text
1) $OPENCODE_BUILD_ARTIFACT                  # 包内 artifact/（随包交付）
2) $HOME/artifact/opencode                   # 手工放置（历史习惯，勿删）
3) $OPENCODE_BUILD_TREE/.../bin/opencode     # 构建树 dist/
4) $HOME/opencode-build-latest/.../opencode  # 历史构建树
5) $HOME/opencode-build/.../opencode         # 历史构建树
6) $OPENCODE_BUILD_INSTALLER_DIR/opencode
7) $OPENCODE_BUILD_INSTALLER_DIR/opencode-linux-arm64
8) $PWD/opencode                             # 当前目录
```

> **注意**：安装器（`opencode-termux.sh`）为**独立运行**设计，**不** source
> `env.sh`，而是用自己的 `find_elf()`（见 §2.3）。其候选规则比上表更简洁，
> 且以「显式指定路径 > 当前目录 > 深度搜索」为序。

### 1.2 安装布局（运行时，沿用现状）

安装到 `$HOME/.local/share/opencode/opencode`，命令入口放 `$HOME/opencode/bin/`，
再从 `$PREFIX/bin/` 建立软链：

```text
$HOME/.local/share/opencode/
├── opencode                 # ELF 本体（真实文件，chmod 700）
├── opencode-termux.sh       # 安装器副本（供 ocdoctor）
├── opencode.db / -wal / -shm# 会话数据库（安装器保留，不清理）
└── log/ repos/ shell/       # 运行时数据（保留）

$HOME/opencode/
└── bin/                     # 启动脚本（真文件，含 exec）
    ├── opencode             # 主入口
    ├── oc                   # 等价 opencode
    ├── ocs                  # → serve（免密，默认 4096）
    ├── ocp                  # → serve --password（带密码）
    ├── ocsp                 # → serve --password（带密码）
    ├── ocrun                # → run
    ├── ocpair               # → pair
    ├── ocmodels             # → models
    └── ocdoctor             # 指向 $HOME/.local/share/opencode/opencode-termux.sh

$PREFIX/bin/<name>           # 全部为软链 → $HOME/opencode/bin/<name>
```

> **软链说明**：命令入口用软链是**安全的**。符号链接是文件系统层的路径别名，
> 由内核在 `open()` 时透明解析，与「ELF 找不到 `libc.so.6`」的 glibc 问题**本质无关**。
> 唯一注意点：ELF **本体**用真实路径（不用软链），避免 `process.execPath` / `argv[0]`
> 拿到软链路径 —— 安装器生成的 `exec` 用的就是真实路径。

### 1.3 补丁分层

构建时采用**分层补丁**，由外到内依次应用，互不覆盖：

| 层 | 位置 | 内容 | 是否本仓库原创 |
|---|---|---|---|
| A. 上游 config delta | `upstream/opencode-bionic/termux/ci/versions.ts` | 改 `package.json` / `bunfig.toml` | 否（第三方）|
| B. 上游 Termux 补丁 | `upstream/opencode-bionic/termux/patches/` | 改构建脚本绕坑 | 否（第三方）|
| C. 本包补丁 | `build/patches/000{1..4}-*.patch` | 构建 harness、回车行为、i18n、免密 serve | **是** |
| D. 本包整树覆盖 | `build/overrides/` | `packages/app/vite-build.mjs` | **是** |

逐文件说明见 `docs/CHANGES.md`。

---

## 2. 安装流程

安装器是**固定流水线**：每一步必须确认正常或结束，才进入下一步。任何一步失败立即 `exit`，
不跳步、不乱序。

### 2.1 命令入口

```text
opencode-termux.sh
├── （无参数）           交互菜单
├── install  [路径]      全新安装
├── reinstall [路径]     卸载重装（y/N 确认）
├── uninstall            卸载（y/N 确认）
├── doctor               只读诊断
└── help                 帮助
```

菜单只有 5 项（**不含回滚**）：

```
1) 全新安装     干净设备：依赖检测 → 依赖安装 → 部署
2) 卸载重装     校验 → 依赖检测 → 安装 → 卸载旧版 → 部署
3) 卸载
4) 诊断
5) 退出
```

> 按需求**不做历史回滚**，因此没有 `versions/` / `current` / `previous` / `rollback` 这类结构。

### 2.2 两种模式的固定流程

**模式 A：全新安装**

```
[1/5] 环境检测        PREFIX / aarch64 / linker64 / HOME 可写
[2/5] 定位 ELF        指定文件 · 指定目录搜索 · 按文件名搜索
[3/5] 哈希校验        不匹配 → 终止（exit 1），不做任何改动
[4/5] 权限            chmod 700（仅在哈希通过后）
[5/5] 依赖检测与安装   pkg update → 逐个 pkg install 缺失项
      ↓ 以上全部成功后
      部署 ELF（复制到 $DATA_DIR，复制后二次校验，原子替换）
      安装诊断副本（$DATA_DIR/opencode-termux.sh）
      注册命令（写启动脚本 + 建软链，ocdoctor 指向诊断副本）
```

**模式 B：卸载重装**

```
[1/5] 环境检测
[2/5] 定位 ELF
[3/5] 哈希校验        不匹配 → 终止，连卸载都不做
[4/5] 权限
[5/5] 依赖检测与安装
      ↓ 先定位 + 校验 + 依赖，确保「确实可装」再执行破坏性卸载
      卸载（仅移除本安装器创建的命令、启动脚本；保留会话数据与配置）
      部署 ELF
      安装诊断副本
      注册命令
```

> **顺序要点**：卸载重装先定位并校验 ELF，再在依赖就绪后卸载。依赖安装失败不会导致旧版被卸载。
> 源 ELF 与已安装 ELF 相同会暂存到 `$HOME/opencode/.tmp/opencode.reinstall`。

### 2.3 ELF 定位规则

优先级从高到低：

1. 命令行参数若为**文件** → 直接采用（先做 ELF 头部校验）；
2. 命令行参数若为**目录** → 在该目录按下列候选查找；
3. 未给参数 → 在**当前目录**按下列候选查找：

```
<dir>/opencode
<dir>/opencode-linux-arm64
<dir>/artifact/opencode
<dir>/bin/opencode
<dir>/../artifact/opencode
```

4. 候选未命中 → `find <dir> -maxdepth 5` 按文件名深度搜索。

### 2.4 流程与状态

| 阶段 | 含义 | 关键动作 |
|---|---|---|
| 环境检测 | 确认平台与权限 | `PREFIX` / `aarch64` / `linker64` / `HOME` 可写 |
| 定位 ELF | 找到候选二进制 | `find_elf()`；先验 ELF 头 |
| **哈希校验** | **硬闸门** | 与内置 `EXPECTED_SHA256` 比对；不匹配即 `exit 1` |
| 权限 | 置可执行位 | `chmod 700`（**仅在哈希通过后**）|
| 依赖 | 缺什么装什么 | 逐个 `pkg install`；任一项失败即终止 |
| 部署 | 落盘 + 注册 | `cp` → `$DATA_DIR` → 写启动脚本 → 建软链 |

**流转规则：**

- 哈希闸门通过之前，**不产生任何副作用**（不 chmod、不复制、不卸载）。
- 卸载重装中，卸载只发生在「定位 + 校验 + 权限 + 依赖」全部成功之后。
- 依赖安装失败时**不进入部署阶段**，且不会卸载现有安装。
- 卸载只清理本安装器创建的命令、启动脚本和软链；有非本安装器的同名文件会跳过并提示。
- 部署时先复制到临时文件，复制后校验 SHA256，再原子替换。
- `ocdoctor` 使用 `$DATA_DIR/opencode-termux.sh`，不依赖源码目录。**保留**会话数据库与配置目录。

---

## 3. 使用速览

```bash
# 交互菜单
bash opencode-termux.sh

# 全新安装（在当前目录按文件名搜索 ELF）
bash opencode-termux.sh install

# 全新安装（指定目录或文件，均为相对本仓库的路径）
bash opencode-termux.sh install ./artifact
bash opencode-termux.sh install ./opencode

# 卸载重装
bash opencode-termux.sh reinstall ./artifact

# 卸载
bash opencode-termux.sh uninstall

# 只读诊断（也可用 ocdoctor）
bash opencode-termux.sh doctor
```

---

## 4. 与其它文档的关系

| 文档 | 说明 |
|---|---|
| `README.md` | 项目概览、快速上手、目录结构、构建步骤（GitHub 首页） |
| `docs/HANDOVER.md` | 完整交接信息（根因分析、构建细节、坑点） |
| `docs/CHANGES.md` | 逐文件改动清单 |
| `docs/INSTALLER.md` | 安装器设计 + git 拉取预留接口 |
| `docs/ARTIFACT-ANALYSIS.md` | 产物 ELF 分析、内嵌资产、依赖检查 |
| `docs/PUBLISHING.md` | GitHub 发布流程 |
| `docs/TROUBLESHOOTING.md` | 常见故障与排查 |
| `docs/ARCHITECTURE.md` | **本文件**：目录架构 + 安装流程 |
| `env.sh` | 路径唯一真源（权威定义） |
