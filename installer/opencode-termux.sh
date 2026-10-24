#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# OpenCode · Termux/Bionic 安装器
#
# 设计目标（按需求固定，不做「回滚 / 历史版本」）：
#   1. 定位 ELF：按文件名搜索，或指定目录/文件
#   2. 哈希校验：与内置预期值不符 -> 立即退出安装并告知使用者
#   3. 权限：仅在哈希通过后 chmod +x
#   4. 弹出安装菜单：全新安装 / 卸载重装
#   5. 依赖检测与依赖安装：两种模式流程一致，且严格串行
#
# 流程是「固定流水线」：每一步必须确认正常或结束，才进入下一步。
# 任何一步失败立即 exit，绝不跳步、绝不乱序。
#
# 安装布局（沿用现状，不改目录）：
#   ELF        $HOME/.local/share/opencode/opencode
#   启动脚本    $HOME/opencode/bin/<name>
#   命令软链    $PREFIX/bin/<name> -> $HOME/opencode/bin/<name>
#
# 用法：
#   bash installer/opencode-termux.sh                 交互菜单
#   bash installer/opencode-termux.sh install [文件或目录]   全新安装（推荐使用 ./artifact 或 ./opencode）
#   bash installer/opencode-termux.sh reinstall [文件或目录] 卸载重装（y/N 确认）
#   bash installer/opencode-termux.sh uninstall        卸载（y/N 确认）
#   bash installer/opencode-termux.sh doctor           本地诊断
#   bash installer/opencode-termux.sh help             帮助
# =============================================================================
set -Eeuo pipefail
umask 077

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ELF_NAME="opencode"

# 预期 SHA256（安装前强制校验；不匹配即拒绝安装）
EXPECTED_SHA256="25cde8a86433852d9e981efde4ee5c1a477dee96bf483d5e14469a0433edb50e"

# 安装目标
DATA_DIR="$HOME/.local/share/opencode"     # ELF 实际存放处
INSTALLER_COPY="$DATA_DIR/opencode-termux.sh" # 供 ocdoctor 使用的安装器副本
CMD_DIR="$HOME/opencode/bin"               # 启动脚本目录
BIN_DIR="$PREFIX/bin"                      # 命令入口（软链）
CFG_DIR="$HOME/.config/opencode"
CACHE_DIR="$HOME/.cache/opencode"
STATE_DIR="$HOME/.local/state/opencode"

# 本安装器生成的启动脚本标记；卸载时据此避免误删用户文件
MANAGED_MARKER="# opencode-termux: managed"

# 注册的命令集（名称 -> 传给 ELF 的参数；空串表示直通）
COMMANDS=(
  "opencode:"
  "oc:"
  "ocs:serve"
  "ocp:serve --password"
  "ocsp:serve --password"
  "ocrun:run"
  "ocpair:pair"
  "ocmodels:models"
)
# 特殊命令：不指向 ELF，而是指向本安装器的 doctor 子命令
SPECIAL_COMMANDS=(ocdoctor)

# 运行时依赖（沿用既有已验证清单）
DEPS=(curl jq git ripgrep coreutils util-linux tar xz-utils zstd termux-tools binutils ca-certificates)
declare -A DEP_CMD=(
  [curl]=curl [jq]=jq [git]=git [ripgrep]=rg [coreutils]=sha256sum
  [util-linux]=flock [tar]=tar [xz-utils]=xz [zstd]=zstd
  [termux-tools]=termux-open-url [binutils]=greadelf [ca-certificates]=__tls__
)

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
ELF_PATH=""

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
  C_BLU=$'\033[1;34m'; C_CYN=$'\033[1;36m'
else
  C_RST=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''
fi

hr()   { printf '%s%s%s\n' "$C_DIM" "------------------------------------------------------------" "$C_RST"; }
die()  { printf '%s[FATAL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
warn() { printf '%s[WARN]%s  %s\n' "$C_YEL" "$C_RST" "$*"; }
info() { printf '%s[INFO]%s  %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[OK]%s    %s\n' "$C_GRN" "$C_RST" "$*"; }
step() { printf '\n%s[STEP %s/%s]%s %s%s%s\n' "$C_BLU" "$1" "$2" "$C_RST" "$C_BOLD" "$3" "$C_RST"; }

# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------
is_elf() {
  local f="$1"
  [[ -f "$f" && -r "$f" ]] || return 1
  if command -v greadelf >/dev/null 2>&1; then greadelf -h "$f" >/dev/null 2>&1; return $?; fi
  if command -v readelf  >/dev/null 2>&1; then readelf  -h "$f" >/dev/null 2>&1; return $?; fi
  [[ "$(od -An -tx1 -j0 -N4 "$f" 2>/dev/null | tr -d ' \n')" == "7f454c46" ]]
}

# 文件 SHA256（调用前必须确认 sha256sum 可用）
sha_of() {
  sha256sum -- "$1" | awk '{print $1}'
}

# 是否为当前发布版 ELF；没有 sha256sum 时退回只做 ELF 头校验
is_expected_elf() {
  local f="$1"
  is_elf "$f" || return 1
  command -v sha256sum >/dev/null 2>&1 || return 0
  [[ "$(sha_of "$f")" == "$EXPECTED_SHA256" ]]
}

# 本安装器生成的启动脚本？
is_managed_script() {
  [[ -f "$1" ]] && grep -qF -- "$MANAGED_MARKER" "$1" 2>/dev/null
}

# 依赖是否满足：$1 = 包名
dep_ok() {
  local pkg="$1" cmd="${DEP_CMD[$1]}"
  if [[ "$cmd" == "__tls__" ]]; then [[ -f "$PREFIX/etc/tls/cert.pem" ]]; return $?; fi
  command -v "$cmd" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# STEP 1/5 环境检测
# ---------------------------------------------------------------------------
env_check() {
  step 1 5 "环境检测"
  [[ -n "${PREFIX:-}" && -d "$PREFIX" ]] || die "需要在 Termux 环境中运行（未检测到 PREFIX）"
  [[ "$(uname -m)" == "aarch64" ]] || die "仅支持 aarch64，当前为 $(uname -m)"
  [[ -x /system/bin/linker64 ]] || die "缺少 Android Bionic linker64（/system/bin/linker64）"
  [[ -n "${HOME:-}" && -d "$HOME" && -w "$HOME" ]] || die "HOME 不可用或不可写"
  info "PREFIX: $PREFIX"
  info "ARCH  : $(uname -m)"
  info "HOME  : $HOME"
  ok "环境检测通过"
}

# ---------------------------------------------------------------------------
# STEP 2/5 定位 ELF
#   两种方式：1) 指定文件或目录  2) 按文件名在常见位置搜索
# ---------------------------------------------------------------------------
find_elf() {
  step 2 5 "定位 ELF（$ELF_NAME）"
  local arg="${1:-}"
  local search_dir=""

  if [[ -n "$arg" ]]; then
    if [[ -d "$arg" ]]; then
      search_dir="$(cd -- "$arg" && pwd)"
      info "在指定目录中查找：$search_dir"
    elif [[ -f "$arg" ]]; then
      local ap; ap="$(cd -- "$(dirname -- "$arg")" && pwd)/$(basename -- "$arg")"
      is_elf "$ap" || die "指定文件不是有效的 ELF：$ap"
      ELF_PATH="$ap"; ok "使用指定文件：$ELF_PATH"; return 0
    else
      die "参数无效：$arg（既不是文件也不是目录）"
    fi
  else
    search_dir="$(pwd)"
    info "未指定路径，按文件名在当前目录搜索：$search_dir"
  fi

  # 按文件名在候选位置查找。优先选哈希匹配的候选；没有哈希匹配时
  # 保留第一个 ELF 交给哈希闸门，让错误信息仍然明确。
  local cand fallback=""
  for cand in \
    "$search_dir/$ELF_NAME" \
    "$search_dir/opencode-linux-arm64" \
    "$search_dir/artifact/$ELF_NAME" \
    "$search_dir/bin/$ELF_NAME" \
    "$search_dir/../artifact/$ELF_NAME"
  do
    is_elf "$cand" || continue
    [[ -n "$fallback" ]] || fallback="$cand"
    if is_expected_elf "$cand"; then
      ELF_PATH="$(cd -- "$(dirname -- "$cand")" && pwd)/$(basename -- "$cand")"
      ok "找到匹配当前版本的 ELF：$ELF_PATH"; return 0
    fi
  done

  info "候选位置未命中，深度搜索（maxdepth 5）..."
  local f
  while IFS= read -r f; do
    is_elf "$f" || continue
    [[ -n "$fallback" ]] || fallback="$f"
    if is_expected_elf "$f"; then
      ELF_PATH="$(cd -- "$(dirname -- "$f")" && pwd)/$(basename -- "$f")"
      ok "找到匹配当前版本的 ELF：$ELF_PATH"; return 0
    fi
  done < <(find "$search_dir" -maxdepth 5 -type f \
             \( -name "$ELF_NAME" -o -name "opencode-linux-arm64" \) 2>/dev/null)

  if [[ -n "$fallback" ]]; then
    ELF_PATH="$(cd -- "$(dirname -- "$fallback")" && pwd)/$(basename -- "$fallback")"
    warn "没有找到哈希完全匹配的候选，使用第一个 ELF 进入哈希闸门：$ELF_PATH"
    return 0
  fi

  die "未找到 $ELF_NAME。请把它放在当前目录，或用：bash $0 install <目录|文件>"
}

# ---------------------------------------------------------------------------
# 【预留】从 Git 拉取新文件 + 校验
#
# 状态：接口预留，尚未实现。设计流程见 docs/INSTALLER.md §5。
# 接入后，mode_fresh_install / mode_reinstall 的 ELF 定位来源增加一种「remote」：
#   拉取到 $TMP_DIR -> 以清单 sha256 校验 -> 再走现有 hash_check 闸门
#
# 约定（实现时填写）：
#   OPENCODE_REPO_URL   仓库地址
#   OPENCODE_REPO_REF   分支/标签（默认 main）
#   产物路径            仓库内固定路径（如 artifact/opencode）
#   清单路径            仓库内固定路径（如 artifact/opencode.sha256）
# ---------------------------------------------------------------------------
TMP_DIR="$HOME/opencode/.tmp"
fetch_from_git() {
  # TODO(预留): 实现后替换此提示。
  #   1. git clone --depth 1 --branch "$OPENCODE_REPO_REF" "$OPENCODE_REPO_URL" "$TMP_DIR/fetch"
  #   2. 读取 "$TMP_DIR/fetch/artifact/opencode.sha256" 作为清单
  #   3. 以脚本内置 EXPECTED_SHA256 核对清单自身未被篡改（信任锚）
  #   4. 设 ELF_PATH="$TMP_DIR/fetch/artifact/opencode"，交由 hash_check 复核
  die "从 Git 拉取功能尚未实现（见 docs/INSTALLER.md §5）"
}

# ---------------------------------------------------------------------------
# STEP 3/5 哈希校验（核心闸门）
#   不匹配 -> 退出安装并明确告知使用者
# ---------------------------------------------------------------------------
hash_check() {
  step 3 5 "哈希校验"
  command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum（coreutils）"
  local actual
  actual="$(sha256sum "$ELF_PATH" | awk '{print $1}')"
  info "文件  ：$ELF_PATH"
  info "预期  ：$EXPECTED_SHA256"
  info "实际  ：$actual"
  if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
    printf '\n' >&2
    printf '%s哈希校验失败，已终止安装，未做任何改动。%s\n' "$C_RED$C_BOLD" "$C_RST" >&2
    printf '  文件路径：%s\n' "$ELF_PATH" >&2
    printf '  预期值  ：%s\n' "$EXPECTED_SHA256" >&2
    printf '  实际值  ：%s\n' "$actual" >&2
    printf '  请确认文件来源正确、未损坏、且与本安装器内置的版本一致。\n' >&2
    exit 1
  fi
  ok "哈希校验通过"
}

# ---------------------------------------------------------------------------
# STEP 4/5 权限
#   仅在哈希通过后执行
# ---------------------------------------------------------------------------
perm_set() {
  step 4 5 "设置可执行权限"
  chmod 700 -- "$ELF_PATH" || die "chmod 失败：$ELF_PATH"
  ok "已设置权限：700"
}

# ---------------------------------------------------------------------------
# STEP 5/5 依赖检测与安装（两种模式共用）
#   缺什么装什么；pkg 更新在前，安装在后，严格串行
# ---------------------------------------------------------------------------
deps_ensure() {
  step 5 5 "依赖检测与安装"
  local -a miss=() p
  for p in "${DEPS[@]}"; do dep_ok "$p" || miss+=("$p"); done

  if (( ${#miss[@]} == 0 )); then
    ok "所有依赖已满足：${DEPS[*]}"
    return 0
  fi

  info "缺失依赖：${miss[*]}"
  info "执行 pkg update"
  if ! pkg update -y; then
    warn "pkg update 未成功，仍继续尝试安装缺失项"
  fi
  for p in "${miss[@]}"; do
    info "pkg install $p"
    pkg install -y "$p" || die "依赖安装失败：$p"
    ok "$p 已安装"
  done
  ok "依赖处理完成"
}

# ---------------------------------------------------------------------------
# 安装动作（幂等；仅在依赖就绪后调用）
# ---------------------------------------------------------------------------
do_place_elf() {
  mkdir -p "$DATA_DIR" "$CMD_DIR" "$BIN_DIR" "$CFG_DIR" "$CACHE_DIR" "$STATE_DIR"
  local dst="$DATA_DIR/$ELF_NAME" tmp actual
  if [ -e "$dst" ] && [ -e "$ELF_PATH" ] && [ "$ELF_PATH" -ef "$dst" ]; then
    info "源 ELF 与目标相同，跳过复制：$dst"
  else
    tmp="$(mktemp "$DATA_DIR/.opencode.XXXXXX")" || die "创建临时文件失败"
    info "复制 ELF -> $dst（先写临时文件）"
    if ! cp -f -- "$ELF_PATH" "$tmp"; then
      rm -f -- "$tmp"
      die "复制 ELF 失败"
    fi
    if ! chmod 700 -- "$tmp"; then
      rm -f -- "$tmp"
      die "设置临时 ELF 权限失败"
    fi
    # 复制后再校验一次，避免磁盘/中断导致半截文件被当成可用 ELF
    actual="$(sha_of "$tmp")"
    if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
      rm -f -- "$tmp"
      die "复制后哈希不一致：预期 $EXPECTED_SHA256，实际 $actual"
    fi
    mv -f -- "$tmp" "$dst" || { rm -f -- "$tmp"; die "替换 ELF 失败"; }
  fi
  chmod 700 -- "$dst" || die "设置 ELF 权限失败"
  ok "ELF 已就位：$dst"
  rm -f -- "$TMP_DIR/opencode.reinstall" 2>/dev/null || true
}

# 安装器自身副本：ocdoctor 不能依赖用户之后可能删除的源码目录
install_self_copy() {
  mkdir -p -- "$DATA_DIR"
  if [[ -e "$INSTALLER_COPY" && "$SCRIPT_PATH" -ef "$INSTALLER_COPY" ]]; then
    info "诊断副本已是最新：$INSTALLER_COPY"
    return 0
  fi
  info "安装诊断副本 -> $INSTALLER_COPY"
  cp -f -- "$SCRIPT_PATH" "$INSTALLER_COPY" || die "复制安装器失败"
  chmod 700 -- "$INSTALLER_COPY" || die "设置安装器副本权限失败"
  ok "诊断副本已就位：$INSTALLER_COPY"
}

do_register() {
  local entry name args
  install_self_copy
  for entry in "${COMMANDS[@]}"; do
    name="${entry%%:*}"
    args="${entry#*:}"
    cat > "$CMD_DIR/$name" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
$MANAGED_MARKER
export PATH="$PREFIX/bin:\$PATH"
export OPENCODE_DISABLE_AUTOUPDATE=true
exec "$DATA_DIR/$ELF_NAME"${args:+ $args} "\$@"
EOF
    chmod 700 -- "$CMD_DIR/$name"
    ln -sfn -- "$CMD_DIR/$name" "$BIN_DIR/$name"
    ok "注册命令：$name"
  done
  # ocdoctor：指向 $DATA_DIR 下的安装器副本，不依赖源码目录
  local sc
  for sc in "${SPECIAL_COMMANDS[@]}"; do
    cat > "$CMD_DIR/$sc" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
$MANAGED_MARKER
exec "$INSTALLER_COPY" doctor "\$@"
EOF
    chmod 700 -- "$CMD_DIR/$sc"
    ln -sfn -- "$CMD_DIR/$sc" "$BIN_DIR/$sc"
    ok "注册命令：$sc（诊断，指向已安装的安装器副本）"
  done
}

do_summary() {
  hr
  printf '%s安装完成%s\n' "$C_GRN$C_BOLD" "$C_RST"
  printf '  ELF    ：%s\n' "$DATA_DIR/$ELF_NAME"
  printf '  启动脚本：%s\n' "$CMD_DIR"
  printf '  命令入口：%s\n' "$BIN_DIR"
  hr
}

# ---------------------------------------------------------------------------
# 模式 A：全新安装（用于干净设备）
#   流程：env_check -> find_elf -> hash_check -> perm_set -> deps_ensure
#          -> place_elf -> register
# ---------------------------------------------------------------------------
mode_fresh_install() {
  hr; printf '%s%s全新安装%s\n' "$C_BOLD" "$C_CYN" "$C_RST"; hr
  env_check
  find_elf "${1:-}"
  hash_check
  perm_set
  deps_ensure
  do_place_elf
  do_register
  do_summary
}

# ---------------------------------------------------------------------------
# 模式 B：卸载重装
#   流程：env_check -> find_elf -> hash_check -> perm_set
#          -> 卸载 -> deps_ensure -> place_elf -> register
#   （先定位+校验+依赖，确保「确实可装」再执行破坏性卸载）
# ---------------------------------------------------------------------------
stage_reinstall_source_if_target() {
  [ -e "$DATA_DIR/$ELF_NAME" ] || return 0
  [ -e "$ELF_PATH" ] || return 0
  if [ "$ELF_PATH" -ef "$DATA_DIR/$ELF_NAME" ]; then
    mkdir -p -- "$TMP_DIR"
    local staged="$TMP_DIR/opencode.reinstall"
    cp -f -- "$ELF_PATH" "$staged" || die "暂存源 ELF 失败"
    chmod 700 -- "$staged" || die "设置暂存 ELF 权限失败"
    ELF_PATH="$staged"
    info "检测到源 ELF 就是已安装文件，已暂存到 $staged"
  fi
}

mode_reinstall() {
  hr; printf '%s%s卸载重装%s\n' "$C_BOLD" "$C_YEL" "$C_RST"; hr
  env_check
  find_elf "${1:-}"
  hash_check
  perm_set
  stage_reinstall_source_if_target
  # 依赖先于卸载：pkg 安装失败时，现有安装仍然可用
  deps_ensure
  do_uninstall
  echo
  do_place_elf
  do_register
  do_summary
}

# ---------------------------------------------------------------------------
# 卸载：只清理本安装器创建的命令与 ELF；保留数据/配置（会话数据不动）
# ---------------------------------------------------------------------------
remove_registered_command() {
  local name="$1" link="$BIN_DIR/$name" target="$CMD_DIR/$name" raw
  if [[ -L "$link" ]]; then
    raw="$(readlink -- "$link" 2>/dev/null || true)"
    if [[ "$raw" == "$target" ]]; then
      rm -f -- "$link"
      [[ ! -e "$target" ]] || rm -f -- "$target"
      return 0
    fi
    warn "跳过非本安装器创建的命令入口：$link -> $raw"
    return 0
  fi
  if [[ -e "$link" ]]; then
    warn "跳过非本安装器创建的命令入口：$link"
  fi
  if is_managed_script "$target"; then
    rm -f -- "$target"
  elif [[ -e "$target" ]]; then
    warn "跳过非本安装器创建的启动脚本：$target"
  fi
}

do_uninstall() {
  hr; printf '%s卸载%s\n' "$C_BOLD" "$C_RST"; hr
  local entry name
  for entry in "${COMMANDS[@]}"; do
    name="${entry%%:*}"
    remove_registered_command "$name"
  done
  local sc
  for sc in "${SPECIAL_COMMANDS[@]}"; do
    remove_registered_command "$sc"
  done
  ok "命令与启动脚本已移除（仅限本安装器创建的文件）"
  rm -f -- "$INSTALLER_COPY"
  ok "安装器副本已移除"
  rm -f -- "$DATA_DIR/$ELF_NAME"
  ok "ELF 已移除"
  rm -f -- "$TMP_DIR/opencode.reinstall"
  printf '\n'
  info "已保留：$DATA_DIR（会话与数据库）"
  info "已保留：$CFG_DIR、$CACHE_DIR、$STATE_DIR"
}

# ---------------------------------------------------------------------------
# 诊断
# ---------------------------------------------------------------------------
do_doctor() {
  hr; printf '%s诊断%s\n' "$C_BOLD" "$C_RST"; hr
  local entry name actual=""
  printf '安装器   ：%s\n' "$SCRIPT_PATH"
  printf '诊断副本 ：%s ' "$INSTALLER_COPY"
  if [[ -x "$INSTALLER_COPY" ]]; then printf '(存在)\n'; else printf '(缺失，请重装)\n'; fi
  printf 'PREFIX   ：%s\n' "$PREFIX"
  printf 'ARCH     ：%s\n' "$(uname -m)"
  printf 'ELF      ：%s ' "$DATA_DIR/$ELF_NAME"
  if [[ -f "$DATA_DIR/$ELF_NAME" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha_of "$DATA_DIR/$ELF_NAME")"
      printf '(存在) %s\n' "$actual"
    else
      printf '(存在，缺少 sha256sum 无法校验)\n'
    fi
  else
    printf '(缺失)\n'
  fi
  printf '预期哈希 ：%s\n' "$EXPECTED_SHA256"
  if [[ -n "$actual" ]]; then
    if [[ "$actual" == "$EXPECTED_SHA256" ]]; then printf '哈希状态 ：匹配\n'; else printf '哈希状态 ：不匹配\n'; fi
  fi
  echo
  printf '命令状态：\n'
  for entry in "${COMMANDS[@]}"; do
    name="${entry%%:*}"
    if [[ -L "$BIN_DIR/$name" && "$(readlink -- "$BIN_DIR/$name" 2>/dev/null || true)" == "$CMD_DIR/$name" && -x "$CMD_DIR/$name" ]]; then
      printf '  ✔ %-10s -> %s\n' "$name" "$CMD_DIR/$name"
    else
      printf '  ✘ %-10s (未注册或不是本安装器创建的软链)\n' "$name"
    fi
  done
  local sc
  for sc in "${SPECIAL_COMMANDS[@]}"; do
    if [[ -L "$BIN_DIR/$sc" && "$(readlink -- "$BIN_DIR/$sc" 2>/dev/null || true)" == "$CMD_DIR/$sc" && -x "$CMD_DIR/$sc" ]]; then
      printf '  ✔ %-10s -> %s（安装器诊断）\n' "$sc" "$CMD_DIR/$sc"
    else
      printf '  ✘ %-10s (未注册或不是本安装器创建的软链)\n' "$sc"
    fi
  done
  echo
  printf '依赖状态：\n'
  local p
  for p in "${DEPS[@]}"; do
    if dep_ok "$p"; then printf '  ✔ %s\n' "$p"; else printf '  ✘ %s (缺失)\n' "$p"; fi
  done
  hr
}

# ---------------------------------------------------------------------------
# 菜单（只选模式，不改流程）
# ---------------------------------------------------------------------------
menu() {
  hr
  printf '%s%sOpenCode Termux 安装器%s\n' "$C_BOLD" "$C_CYN" "$C_RST"
  hr
  echo
  printf '  %s1)%s 全新安装   %s（干净设备：依赖检测 -> 安装 -> 部署）%s\n' "$C_GRN" "$C_RST" "$C_DIM" "$C_RST"
  printf '  %s2)%s 卸载重装   %s（校验 -> 依赖 -> 卸载 -> 部署）%s\n' "$C_YEL" "$C_RST" "$C_DIM" "$C_RST"
  printf '  %s3)%s 卸载\n' "$C_RED" "$C_RST"
  printf '  %s4)%s 诊断\n' "$C_BLU" "$C_RST"
  printf '  %s5)%s 退出\n' "$C_DIM" "$C_RST"
  echo
  printf '%s当前目录：%s%s\n' "$C_DIM" "$(pwd)" "$C_RST"
  echo
  local c
  read -rp "请选择 [1-5]: " c || exit 0
  case "$c" in
    1) mode_fresh_install ;;
    2) local yn; read -rp "确认卸载重装？[y/N]: " yn || exit 0
       [[ "$yn" =~ ^[Yy]$ ]] || { warn "已取消"; exit 0; }
       mode_reinstall ;;
    3) local yn; read -rp "确认卸载？[y/N]: " yn || exit 0
       [[ "$yn" =~ ^[Yy]$ ]] || { warn "已取消"; exit 0; }
       do_uninstall ;;
    4) do_doctor ;;
    5) exit 0 ;;
    *) warn "无效选择"; menu ;;
  esac
}

usage() {
  cat <<EOF
用法：
  bash $0                    交互菜单
  bash $0 install  [文件或目录]     全新安装（推荐 ./artifact 或 ./opencode）
  bash $0 reinstall [文件或目录]    卸载重装（y/N 确认）
  bash $0 uninstall              卸载（y/N 确认）
  bash $0 doctor                 诊断
  bash $0 help                   本帮助

路径省略时，在当前目录按文件名 "$ELF_NAME" 搜索。
安装前强制校验 SHA256；不匹配即终止安装。
EOF
}

main() {
  case "${1:-}" in
    "")            menu ;;
    install)       shift; mode_fresh_install "${1:-}" ;;
    reinstall)     shift
                   read -rp "确认卸载重装？[y/N]: " yn || exit 0
                   [[ "$yn" =~ ^[Yy]$ ]] || { warn "已取消"; exit 0; }
                   mode_reinstall "${1:-}" ;;
    uninstall)
                   read -rp "确认卸载？[y/N]: " yn || exit 0
                   [[ "$yn" =~ ^[Yy]$ ]] || { warn "已取消"; exit 0; }
                   do_uninstall ;;
    doctor)        do_doctor ;;
    help|-h|--help) usage ;;
    *)             usage; exit 1 ;;
  esac
}

main "$@"
