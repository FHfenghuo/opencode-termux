#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# OpenCode · Termux/Bionic 交接包 —— 路径唯一真源 (single source of truth)
# =============================================================================
#
# 构建/校验脚本必须从这里取路径，禁止硬编码 `$HOME/...` 之类的绝对路径。
# 安装器 `installer/opencode-termux.sh` 为独立分发设计，不 source 本文件；
# 它内置的安装路径必须与这里的口径保持一致。
#
# 用法：
#   source "<包根>/env.sh"
#
# 覆盖方式（环境变量优先，便于 CI / 交叉构建）：
#   OPENCODE_INSTALL_ROOT   安装目标目录，默认 $HOME/opencode
#   OPENCODE_BUILD_TREE     构建树目录，默认 $HOME/src/build-tree
#   OPENCODE_BUILD_ARTIFACT 产物二进制路径，默认 <包根>/artifact/opencode
#
# 本文件只定义变量与函数，不产生副作用，可安全地被重复 source。
# =============================================================================

# 包根目录 = 本文件所在目录
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  OPENCODE_BUILD_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
else
  OPENCODE_BUILD_ROOT="$(pwd)"
fi
export OPENCODE_BUILD_ROOT

# ---------------------------------------------------------------------------
# 包内目录：每个目录只有一个职责
# ---------------------------------------------------------------------------
export OPENCODE_BUILD_ARTIFACT_DIR="$OPENCODE_BUILD_ROOT/artifact"    # 成品：二进制 + 校验和
export OPENCODE_BUILD_INSTALLER_DIR="$OPENCODE_BUILD_ROOT/installer"  # 成品：安装器
export OPENCODE_BUILD_BUILD_DIR="$OPENCODE_BUILD_ROOT/build"          # 源：补丁 / 覆盖 / 构建脚本
export OPENCODE_BUILD_DOCS_DIR="$OPENCODE_BUILD_ROOT/docs"            # 文档
export OPENCODE_BUILD_UPSTREAM_DIR="$OPENCODE_BUILD_ROOT/upstream/opencode-bionic" # 第三方构建器

# ---------------------------------------------------------------------------
# 成品
# ---------------------------------------------------------------------------
export OPENCODE_BUILD_ARTIFACT="${OPENCODE_BUILD_ARTIFACT:-$OPENCODE_BUILD_ARTIFACT_DIR/opencode}"
export OPENCODE_BUILD_ARTIFACT_SHA256="${OPENCODE_BUILD_ARTIFACT_SHA256:-$OPENCODE_BUILD_ARTIFACT_DIR/opencode.sha256}"

# ---------------------------------------------------------------------------
# 安装目标（安装器写入的目录）
# ---------------------------------------------------------------------------
export OPENCODE_INSTALL_ROOT="${OPENCODE_INSTALL_ROOT:-$HOME/opencode}"

# ---------------------------------------------------------------------------
# 构建树（放包外，避免污染交付物；2G+ node_modules）
# ---------------------------------------------------------------------------
export OPENCODE_BUILD_TREE="${OPENCODE_BUILD_TREE:-$HOME/src/build-tree}"

# ---------------------------------------------------------------------------
# 产物候选路径：安装器与校验脚本共用的唯一查找顺序
# ---------------------------------------------------------------------------
# 顺序含义：
#   1) 包内 artifact/      —— 随包交付的正式产物
#   2) $HOME/artifact/     —— 手工放置的产物（历史习惯位置，勿删）
#   3) 构建树 dist/        —— 刚构建出来、还没归档的产物
#   4) 其它历史构建树      —— 旧版本残留
#   5) 安装器同级 / 当前目录 —— 就地放置的裸二进制
opencode_artifact_candidates() {
  printf '%s\n' \
    "$OPENCODE_BUILD_ARTIFACT" \
    "$HOME/artifact/opencode" \
    "$OPENCODE_BUILD_TREE/packages/cli/dist/cli-linux-arm64/bin/opencode" \
    "$HOME/opencode-build-latest/packages/cli/dist/cli-linux-arm64/bin/opencode" \
    "$HOME/opencode-build/packages/cli/dist/cli-linux-arm64/bin/opencode" \
    "$OPENCODE_BUILD_INSTALLER_DIR/opencode" \
    "$OPENCODE_BUILD_INSTALLER_DIR/opencode-linux-arm64" \
    "$PWD/opencode"
}

# ---------------------------------------------------------------------------
# 常用派生路径
# ---------------------------------------------------------------------------
export OPENCODE_BUILD_DIST_BIN="$OPENCODE_BUILD_TREE/packages/cli/dist/cli-linux-arm64/bin/opencode"

# ---------------------------------------------------------------------------
# Bionic 资产的 sha256
# ---------------------------------------------------------------------------
# 资产的**版本与 URL** 的唯一真源是 upstream/opencode-bionic/versions.json
# （build/build.sh 第 0 步直接读它）。这里只额外记录 sha256 ——
# 构建后用来核对「产物里内嵌的确实是我们放进来的那个 Bionic 版」，
# 由 build/verify.sh 第 4 步的 --expect 强制比对。
# 改动资产版本时，sha256 与 versions.json 两边必须同步。
export OPENCODE_BUN_PTY_SHA256="179b2b30748d73167898397a5f51388d9d5645b94504c8d092e7ede0efac0b0c"
export OPENCODE_PTY_SERVICE_SHA256="8d62b709722551109701f192310b70c5645f8ecf30d7b8f0c15cb920b1f3b5df"

# 产物元信息
export OPENCODE_VERSION="${OPENCODE_VERSION:-2.1.2-dev}"
export OPENCODE_CHANNEL="${OPENCODE_CHANNEL:-dev}"
export OPENCODE_UPSTREAM_REF="${OPENCODE_UPSTREAM_REF:-4d5965762ec5e0d1a0b14630553fc62b51a11fba}"
