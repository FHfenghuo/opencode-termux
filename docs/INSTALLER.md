# 安装器设计文档

> 对应脚本：`installer/opencode-termux.sh`
> 目标平台：Android / Termux，aarch64，Bionic（无 glibc）

---

## 1. 设计原则

1. **固定流水线，严格串行**：每一步必须确认正常或结束，才进入下一步。失败立即退出，不跳步、不乱序。
2. **哈希是硬闸门**：任何 ELF 在部署前必须通过 SHA256 校验；不匹配即终止安装，**不做任何改动**并明确告知使用者。
3. **不改目录**：安装位置与现有运行态一致，见 §2。
4. **不做历史回滚**：本安装器只维护「当前这一份」，不保留版本历史（按需求裁掉）。
5. **诊断不依赖源码目录**：安装时把安装器自身复制到 `$DATA_DIR/opencode-termux.sh`，供 `ocdoctor` 使用；`~/opencode/bin/` 只放启动脚本。

---

## 2. 安装布局（沿用现状）

| 角色 | 路径 |
|---|---|
| ELF 实际存放 | `$HOME/.local/share/opencode/opencode` |
| 安装器副本 | `$HOME/.local/share/opencode/opencode-termux.sh`（供 `ocdoctor`）|
| 启动脚本 | `$HOME/opencode/bin/<name>`（真文件，含 `exec`）|
| 命令入口 | `$PREFIX/bin/<name>` → 软链到启动脚本 |
| 配置 / 缓存 / 状态 | `$HOME/.config/opencode`、`$HOME/.cache/opencode`、`$HOME/.local/state/opencode` |

> **软链说明**：命令入口用软链是**安全的**。符号链接是文件系统层的路径别名，
> 由内核在 `open()` 时透明解析，与「ELF 找不到 `libc.so.6`」的 glibc 问题**本质无关**。
> 唯一注意点：ELF **本体**用真实路径（不用软链），避免 `process.execPath` / `argv[0]`
> 拿到软链路径影响「自我更新」等功能 —— 本安装器的 `exec` 用的就是真实路径。

### 2.1 注册的命令集

| 命令 | 传给 ELF 的参数 |
|---|---|
| `opencode` | （无）|
| `oc` | （无）|
| `ocs` | `serve`（免密，默认 4096）|
| `ocp` | `serve --password`（带密码）|
| `ocsp` | `serve --password`（带密码）|
| `ocrun` | `run` |
| `ocpair` | `pair` |
| `ocmodels` | `models` |
| `ocdoctor` | 指向 `$DATA_DIR/opencode-termux.sh` 的 `doctor` |

---

## 3. 流程

### 3.1 模式 A：全新安装（干净设备）

```
[1/5] 环境检测     PREFIX / aarch64 / linker64 / HOME 可写
[2/5] 定位 ELF     指定文件 或 指定目录搜索 或 按文件名搜索
[3/5] 哈希校验     不匹配 -> 终止（exit 1），不做任何改动
[4/5] 权限         chmod 700（仅在哈希通过后）
[5/5] 依赖检测与安装  pkg update -> 逐个 pkg install 缺失项
      ↓ 以上全部成功后
      部署 ELF（复制到 DATA_DIR，复制后二次校验，原子替换）
      安装诊断副本（DATA_DIR/opencode-termux.sh）
      注册命令（写启动脚本 + 建软链，ocdoctor 指向诊断副本）
```

### 3.2 模式 B：卸载重装

```
[1/5] 环境检测
[2/5] 定位 ELF
[3/5] 哈希校验     不匹配 -> 终止，连卸载都不做
[4/5] 权限
[5/5] 依赖检测与安装
      ↓ 先定位+校验+依赖，确保「确实可装」，再执行破坏性卸载
      卸载（仅移除本安装器创建的命令、启动脚本；保留会话数据与配置）
      部署 ELF
      安装诊断副本
      注册命令
```

> **顺序要点**：卸载重装**先定位并校验 ELF**，并在卸载前先确保依赖可用。只有确认新 ELF 可装且依赖就绪时才执行卸载，避免依赖安装失败导致无可用安装。
> 源 ELF 与已安装 ELF 相同（重装时直接从安装目录指定）会先暂存到 `$HOME/opencode/.tmp/opencode.reinstall`，避免复制自身失败。

### 3.3 ELF 定位规则

优先级从高到低：

1. 命令行参数若为**文件** → 直接采用；
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

---

## 4. 依赖清单

```
curl jq git ripgrep coreutils util-linux tar xz-utils zstd termux-tools binutils ca-certificates
```

| 包 | 用于 |
|---|---|
| curl | 后续 git-pull 功能下载 / 现有网络操作 |
| jq | 解析 manifest 等 JSON |
| git | 后续从 Git 仓库拉取（§5）|
| ripgrep | 运行时 / 诊断 |
| coreutils | `sha256sum` 等 |
| util-linux | `flock` |
| tar / xz-utils / zstd | 解包压缩产物 |
| termux-tools | `termux-open-url` |
| binutils | `greadelf`（ELF 校验）|
| ca-certificates | TLS 根证书 |

检测方式见脚本 `DEP_CMD` 映射（`ca-certificates` 以 `$PREFIX/etc/tls/cert.pem` 是否存在判定）。

---

## 5. 【预留】从 Git 拉取新文件 + 校验

> **状态：接口已预留，尚未实现。** 本节定义设计流程，实现时按此填充。

### 5.1 目标

让安装器能从指定 Git 仓库拉取**最新产物 + 其校验和**，并把校验和的权威值
从「脚本内置常量」切换为「随产物下发的清单」，同时仍保留内置值作为**信任锚**。

### 5.2 建议流程（并入现有流水线）

在「环境检测」与「定位 ELF」之间插入一个新步骤，或作为 `install` 的模式参数：

```
[新] 拉取          git clone/fetch 指定仓库（或打包好的 release 资产）
[新] 校验清单     校验下载到的清单文件本身的签名/哈希（信任锚 = 脚本内置值）
[2/5] 定位 ELF     指向拉取下来的 ELF
[3/5] 哈希校验     以清单里的 sha256 为准，与拉取到的 ELF 比对
```

### 5.3 接口约定（实现时使用）

| 项 | 约定 |
|---|---|
| 仓库地址 | 环境变量 `OPENCODE_REPO_URL`，或脚本常量 |
| 分支/标签 | `OPENCODE_REPO_REF`，默认 `main` |
| 产物路径 | 仓库内固定路径（如 `artifact/opencode`）|
| 校验和文件 | 仓库内固定路径（如 `artifact/opencode.sha256`）|
| 清单格式 | 与现有 `artifact/opencode.sha256` 一致：`<sha256>  <相对路径>` |
| 信任锚 | 脚本内置 `EXPECTED_SHA256`；拉取模式下用于核对清单未被篡改 |
| 暂存目录 | `$HOME/opencode/.tmp`（已存在），拉取与校验都在此完成后再部署 |
| 失败处理 | 任一步失败 → 终止，保留当前已安装版本不动 |

### 5.4 待定问题（实现前需明确）

1. 清单的签名方式（GPG？还是仅 sha256 + HTTPS？）
2. 拉取整仓还是仅 release 资产（191 MB 二进制不宜进 git，倾向 release 资产）
3. 是否需要「检查更新但不自动安装」的独立子命令（如 `check-update`）

### 5.5 实现落点

- 脚本中预留函数位：`fetch_from_git()`（当前未定义，调用点未接入）。
- 接入后，`mode_fresh_install` / `mode_reinstall` 的 ELF 定位来源增加一种：`remote`。

---

## 6. 安全与容错

| 场景 | 行为 |
|---|---|
| 哈希不匹配 | 终止安装，`exit 1`，打印预期值/实际值/路径，不做任何改动 |
| 非 aarch64 | 终止 |
| 缺 linker64 | 终止 |
| 依赖安装失败 | 终止（不进入部署阶段）|
| ELF 未找到 | 终止，并提示如何指定路径 |
| 卸载重装时新 ELF 无效 | 因「先校验后卸载」，当前安装保持完好 |
| 重装时依赖安装失败 | 因「校验+依赖在卸载前」，不会先卸载旧安装 |
| 重装源就是已安装 ELF | 先暂存到 `$HOME/opencode/.tmp/opencode.reinstall`，卸载后再部署，避免复制自身失败 |
| 误删用户同名文件 | 卸载只移除本安装器创建的启动脚本和软链（有标记/目标校验） |
| 源码目录被删除后 ocdoctor 失效 | 已安装 `$DATA_DIR/opencode-termux.sh` 作为诊断副本，由 `ocdoctor` 使用 |

---

## 7. 与其它文件的关系

| 文件 | 关系 |
|---|---|
| `env.sh` | 提供产物路径变量；本安装器为「独立运行」保留内置路径，二者口径需一致 |
| `artifact/opencode.sha256` | 内置 `EXPECTED_SHA256` 应与之保持同步 |
| `build/patches/*.patch` | 产物由这些补丁构建而来，见 `docs/CHANGES.md` |
| `build/verify.sh` | 产物级别校验（7 步），与安装器的「安装前校验」互补 |
