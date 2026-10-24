# OpenCode Termux

本项目基于 [anomalyco/opencode](https://github.com/anomalyco/opencode) 源码，使用 [bd-loser/opencode-bionic](https://github.com/bd-loser/opencode-bionic) 的 Termux/Bionic 构建流程进行编译，并在其基础上由本仓库进行二次修改、应用补丁后适配于 Android Termux（aarch64）。

## 版本信息

- **上游源码**：`anomalyco/opencode`
- **上游 Commit**：`4d5965762ec5e0d1a0b14630553fc62b51a11fba`
- **构建流程**：`bd-loser/opencode-bionic`
- **产物 SHA256**：`25cde8a86433852d9e981efde4ee5c1a477dee96bf483d5e14469a0433edb50e`

## 安装方式

### 1. 使用离线包（推荐）

从 [Releases](../../releases) 下载 `opencode.zip`，解压并进入目录后安装：

```bash
pkg install unzip
unzip opencode.zip
cd opencode-build
bash installer/opencode-termux.sh install ./artifact
```

### 2. 只下载 ELF 文件

从 [Releases](../../releases) 下载 `opencode` 文件后，将其放入 `opencode-build/` 目录并安装：

```bash
bash installer/opencode-termux.sh install ./opencode
```

也可以将其放入 `opencode-build/artifact/` 目录后安装：

```bash
bash installer/opencode-termux.sh install ./artifact
```

## 可用命令

| 命令 | 用途 |
| --- | --- |
| `opencode`、`oc` | 终端界面 |
| `ocs` | Web UI（免密，默认：`http://127.0.0.1:4096`） |
| `ocp`、`ocsp` | Web UI（密码模式） |
| `ocrun` | 直接运行任务 |
| `ocpair` | 生成配对码 |
| `ocmodels` | 列出可用模型 |
| `ocdoctor` | 检查安装状态与依赖 |

## 更新、卸载

```bash
# 卸载重装
bash installer/opencode-termux.sh reinstall ./artifact

# 卸载
bash installer/opencode-termux.sh uninstall
```