#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# 一键构建：上游源码 → 补丁 → Bionic 资产 → 产物 → 归档到 artifact/
#
# 用法：
#   bash build/build.sh                # 全新构建（会清空构建树）
#   bash build/build.sh --keep-tree    # 保留现有 node_modules，只重跑补丁+构建
#
# 阶段（与 upstream/opencode-bionic/termux/ci/build-in-container.sh 同源，
#       但改为在 Termux 本机执行；共 10 个阶段，0 为环境检查）：
#   0. 环境检查（bun / node / patch / git / curl / sha256sum）
#   1. 拉取上游固定 commit
#   2. 套用上游 config delta（versions.ts）
#   3. 套用上游 Termux 补丁
#   4. 套用本包 build/patches/ 补丁 + build/overrides/ 覆盖
#   5. bun install
#   6. 嵌入 Bionic bun-pty .so（替换 npm 的 glibc 预编译）
#   7. 嵌入 Bionic opencode-pty 常驻守护进程
#   8. 构建 linux-arm64 产物（Web UI 一并嵌入）
#   9. 归档 + 写校验和
# =============================================================================
set -Eeuo pipefail

PKG_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$PKG_ROOT/env.sh"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; BLUE=$'\033[1;34m'; DIM=$'\033[0;2m'; NC=$'\033[0m'
KEEP_TREE=0
[ "${1:-}" = "--keep-tree" ] && KEEP_TREE=1

step() { printf '\n%s==> %s%s\n' "$BLUE" "$1" "$NC"; }
info() { printf '    %s%s%s\n' "$DIM" "$1" "$NC"; }
ok()   { printf '    %s✔%s %s\n' "$GREEN" "$NC" "$1"; }
die()  { printf '\n%s✘ %s%s\n' "$RED" "$1" "$NC" >&2; exit 1; }

export PATH="$PREFIX/bin:$PATH"
for _cmd in bun node git curl patch sha256sum; do
  command -v "$_cmd" >/dev/null 2>&1 || die "缺少命令：$_cmd（Termux 里先安装对应包，见 README「环境要求」）"
done

TREE="$OPENCODE_BUILD_TREE"
UPSTREAM="$OPENCODE_BUILD_UPSTREAM_DIR"

# 构建树的删除保护：TREE 来自环境变量，绝不能为空、根目录、$HOME 或包根。
case "$TREE" in
  ""|"/"|"$HOME"|"$PKG_ROOT") die "OPENCODE_BUILD_TREE 不安全：$TREE" ;;
  /*) ;;
  *) die "OPENCODE_BUILD_TREE 必须是绝对路径：$TREE" ;;
esac

# Bionic 资产版本与 URL 一律从 upstream/opencode-bionic/versions.json 读，
# 不在本脚本里硬编码。env.sh 只保存版本与内嵌资产的 SHA256，不保存 URL。
# 参数走环境变量传，避免 bun / node 的 process.argv 索引差异。
read_json() {
  _RJ_FILE="$UPSTREAM/versions.json" _RJ_KEY="$1" bun -e '
    const j = await Bun.file(process.env._RJ_FILE).json()
    const v = process.env._RJ_KEY.split(".").reduce((a, k) => a?.[k], j)
    process.stdout.write(v == null ? "" : String(v))
  '
}
BUN_PTY_VERSION="$(read_json bunPty.version)"
PTY_SERVICE_VERSION="$(read_json ptyService.version)"
BUN_PTY_URL="$(read_json bunPty.assetUrl)"
PTY_SERVICE_URL="$(read_json ptyService.assetUrl)"
[ -n "$BUN_PTY_VERSION" ] && [ -n "$PTY_SERVICE_VERSION" ] || die "读不到 versions.json 里的资产版本"
[ -n "$BUN_PTY_URL" ] && [ -n "$PTY_SERVICE_URL" ] || die "读不到 versions.json 里的资产 URL"

step "0/9 环境"
info "bun      : $(bun --version)"
info "构建树   : $TREE"
info "上游 ref : $OPENCODE_UPSTREAM_REF"
info "版本     : $OPENCODE_VERSION (channel=$OPENCODE_CHANNEL)"

# ---------------------------------------------------------------------------
# 幂等补丁应用器
# ---------------------------------------------------------------------------
# 为什么需要它：`patch --forward` 对「已经打过」的补丁行为**不确定** ——
# 完全匹配时会报 "Reversed (or previously applied) patch detected" 并跳过；
# 但带 fuzz/offset 匹配时，它可能把某些 hunk **再套一遍**，
# 导致源码里出现重复声明（例如 build.ts 里 opentuiAliasPlugin 声明两次 → 编译失败）。
#
# 所以顺序必须是：先探测（能不能反向 dry-run）→ 再决定要不要应用。
# 另外用标记文件记录已应用的补丁（按 sha256），保证同一棵树反复构建的结果一致。
MARKER="$TREE/.opencode-build/applied-patches"

patch_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# 标记文件惰性创建 —— 第 1 步会 rm -rf 整个构建树，
# 所以不能在脚本开头就把标记文件建好。
marker_has() { [ -f "$MARKER" ] && grep -qxF "$1" "$MARKER" 2>/dev/null; }
marker_add() {
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
  touch "$MARKER" 2>/dev/null || true
  grep -qxF "$1" "$MARKER" 2>/dev/null && return 0
  printf '%s\n' "$1" >> "$MARKER" 2>/dev/null || true
}

# 补丁是否已经应用在这棵树上？
patch_applied() {
  local p="$1"
  if marker_has "$(patch_sha "$p")"; then return 0; fi
  if patch -d "$TREE" -p1 --forward --silent --dry-run -R -i "$p" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# 应用一份补丁；已应用则跳过。成功返回 0。
apply_patch() {
  local p="$1" name sha
  name="$(basename "$p")"
  sha="$(patch_sha "$p")"
  if patch_applied "$p"; then
    info "$name 已应用，跳过"
    marker_add "$sha"
    return 0
  fi
  if patch -d "$TREE" -p1 --forward --silent -i "$p"; then
    ok "$name"
    marker_add "$sha"
    return 0
  fi
  find "$TREE" -name '*.rej' -delete 2>/dev/null || true
  return 1
}

# ---------------------------------------------------------------------------
step "1/9 拉取上游"
# ---------------------------------------------------------------------------
if [ "$KEEP_TREE" -eq 0 ]; then
  case "$TREE" in
    ""|"/"|"$HOME"|"$PKG_ROOT") die "OPENCODE_BUILD_TREE 不安全，拒绝 rm -rf：$TREE" ;;
    /*) ;;
    *) die "OPENCODE_BUILD_TREE 必须是绝对路径：$TREE" ;;
  esac
  rm -rf -- "$TREE"
  mkdir -p -- "$TREE"
  git -C "$TREE" init -q
  git -C "$TREE" remote add origin https://github.com/anomalyco/opencode.git 2>/dev/null || true
  # 必须用完整 sha，短 sha 会被 GitHub 拒绝
  git -C "$TREE" fetch -q --depth 1 origin "$OPENCODE_UPSTREAM_REF"
  git -C "$TREE" checkout -q FETCH_HEAD
fi
ok "上游 commit：$(git -C "$TREE" log -1 --format='%h %ci %s')"

# ---------------------------------------------------------------------------
step "2/9 上游 config delta（versions.ts）"
# ---------------------------------------------------------------------------
OPENCODE_VERSION="$OPENCODE_VERSION" bun "$UPSTREAM/termux/ci/versions.ts" apply --target "$TREE" | tail -5
ok "config delta 已应用"

# ---------------------------------------------------------------------------
step "3/9 上游 Termux 补丁"
UPSTREAM_PATCH_DIR="$UPSTREAM/termux/patches"
shopt -s nullglob
UPSTREAM_PATCHES=("$UPSTREAM_PATCH_DIR"/*.patch)
shopt -u nullglob
if [ ${#UPSTREAM_PATCHES[@]} -eq 0 ]; then
  info "没有上游补丁"
else
  # 先探测：全部都还没应用 -> 走上游脚本（它是权威实现，冲突时响亮失败）。
  # 只要有一份已经应用过（比如 --keep-tree 复用）-> 走幂等路径，
  # 绝不能让上游脚本再 forward 一遍（会重复套用 hunk）。
  PENDING=0
  for p in "${UPSTREAM_PATCHES[@]}"; do
    patch_applied "$p" || PENDING=$((PENDING + 1))
  done
  if [ "$PENDING" -eq "${#UPSTREAM_PATCHES[@]}" ]; then
    if bash "$UPSTREAM/termux/ci/apply-patches.sh" "$TREE" >"$TREE/.upstream-patches.log" 2>&1; then
      tail -8 "$TREE/.upstream-patches.log"
      for p in "${UPSTREAM_PATCHES[@]}"; do marker_add "$(patch_sha "$p")"; done
      ok "上游补丁已应用"
    else
      cat "$TREE/.upstream-patches.log" >&2
      find "$TREE" -name '*.rej' -delete 2>/dev/null || true
      die "上游补丁应用失败（与上游冲突）"
    fi
  else
    info "上游补丁已部分应用，改用幂等方式逐个确认"
    for p in "${UPSTREAM_PATCHES[@]}"; do
      apply_patch "$p" || die "$(basename "$p") 应用失败（与上游冲突）"
    done
    ok "上游补丁已应用（幂等路径）"
  fi
  rm -f "$TREE/.upstream-patches.log"
  find "$TREE" -name '*.rej' -delete 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
step "4/9 本包补丁与覆盖"
# ---------------------------------------------------------------------------
if [ -d "$PKG_ROOT/build/patches" ]; then
  shopt -s nullglob
  OWN_PATCHES=("$PKG_ROOT/build/patches"/*.patch)
  shopt -u nullglob
  for p in "${OWN_PATCHES[@]}"; do
    apply_patch "$p" || die "$(basename "$p") 应用失败（与上游有冲突，或上游已漂移）"
  done
  find "$TREE" -name '*.rej' -delete 2>/dev/null || true
fi
if [ -d "$PKG_ROOT/build/overrides" ]; then
  # overrides/ 是「整树覆盖」语义：目录层级原样映射到构建树。
  #   build/overrides/packages/app/vite-build.mjs
  #     → $TREE/packages/app/vite-build.mjs
  # 所以放文件时必须保留它在构建树里的相对路径，不能平铺。
  while IFS= read -r f; do
    rel="${f#"$PKG_ROOT/build/overrides/"}"
    mkdir -p "$TREE/$(dirname "$rel")"
    cp "$f" "$TREE/$rel"
    [ -f "$TREE/$rel" ] || die "覆盖失败：$rel"
    ok "覆盖 $rel  →  \$TREE/$rel"
  done < <(find "$PKG_ROOT/build/overrides" -type f | sort)
fi

# ---------------------------------------------------------------------------
step "5/9 依赖安装"
# ---------------------------------------------------------------------------
if [ "$KEEP_TREE" -eq 0 ] || [ ! -d "$TREE/node_modules" ]; then
  (cd "$TREE" && bun install)
else
  info "复用已有 node_modules"
fi
ok "node_modules 就绪"

# ---------------------------------------------------------------------------
step "6/9 嵌入 Bionic bun-pty（替换 npm 的 glibc 预编译）"
# ---------------------------------------------------------------------------
# npm 上的 bun-pty 预编译 .so 链接 glibc（libc.so.6/libpthread.so.0），
# 在 Bionic 上 dlopen 必失败。bun-pty 用「静态可分析的 require()」嵌入 .so，
# 所以磁盘上这个文件就是最终产物里内嵌的那份 —— 直接覆盖即可。
PTTY_SO="$TREE/node_modules/.bun/bun-pty@$BUN_PTY_VERSION/node_modules/bun-pty/rust-pty/target/release/librust_pty_arm64.so"
if [ ! -d "$(dirname "$PTTY_SO")" ]; then
  PTTY_SO="$(find "$TREE" -type d -path '*bun-pty/rust-pty/target/release' 2>/dev/null | head -1)/librust_pty_arm64.so"
fi
[ -d "$(dirname "$PTTY_SO")" ] || die "找不到 bun-pty 的 rust-pty/target/release 目录"
curl -fsSL -o "$PTTY_SO" "$BUN_PTY_URL"
chmod 0644 "$PTTY_SO"
if [ -n "${OPENCODE_BUN_PTY_SHA256:-}" ]; then
  _actual="$(sha256sum "$PTTY_SO" | cut -d' ' -f1)"
  [ "$_actual" = "$OPENCODE_BUN_PTY_SHA256" ] || die "bun-pty .so sha256 不匹配（预期 $OPENCODE_BUN_PTY_SHA256，实际 $_actual）"
  unset _actual
fi
if grep -qa 'libc.so.6' "$PTTY_SO"; then die "下载到的 bun-pty .so 仍含 glibc 依赖"; fi
ok "Bionic bun-pty $BUN_PTY_VERSION 已就位"

# ---------------------------------------------------------------------------
step "7/9 嵌入 Bionic opencode-pty 常驻守护进程"
# ---------------------------------------------------------------------------
PTY_PKG="$TREE/node_modules/@opencode-ai/pty-linux-arm64-gnu"
mkdir -p "$PTY_PKG/bin"
curl -fsSL -o "$PTY_PKG/bin/opencode-pty" "$PTY_SERVICE_URL"
chmod 0755 "$PTY_PKG/bin/opencode-pty"
if [ -n "${OPENCODE_PTY_SERVICE_SHA256:-}" ]; then
  _actual="$(sha256sum "$PTY_PKG/bin/opencode-pty" | cut -d' ' -f1)"
  [ "$_actual" = "$OPENCODE_PTY_SERVICE_SHA256" ] || die "pty 守护进程 sha256 不匹配（预期 $OPENCODE_PTY_SERVICE_SHA256，实际 $_actual）"
  unset _actual
fi
cat > "$PTY_PKG/package.json" <<PKGJSON
{
  "name": "@opencode-ai/pty-linux-arm64-gnu",
  "version": "$PTY_SERVICE_VERSION",
  "description": "OpenCode persistent PTY service for linux-arm64 (Bionic build)",
  "license": "MIT",
  "os": ["linux"],
  "cpu": ["arm64"],
  "exports": {
    "./package.json": "./package.json",
    "./bin/opencode-pty": "./bin/opencode-pty"
  },
  "files": ["bin"]
}
PKGJSON
ok "Bionic pty 守护进程 $PTY_SERVICE_VERSION 已就位"

# ---------------------------------------------------------------------------
step "8/9 构建"
# ---------------------------------------------------------------------------
# 注意：不能加 --skip-web-ui，否则 Web UI 不会进产物。
# 也不要在本机并行跑第二个构建 —— Bun 的线程池在 Termux 下会互相干扰。
(cd "$TREE/packages/cli" && \
  OPENCODE_ROOT="$TREE" \
  OPENCODE_CHANNEL="$OPENCODE_CHANNEL" \
  OPENCODE_VERSION="$OPENCODE_VERSION" \
  bun run script/build.ts --target=opencode-linux-arm64 --skip-install)

BIN="$OPENCODE_BUILD_DIST_BIN"
[ -f "$BIN" ] || die "产物没生成：$BIN"
ok "产物：$BIN ($(du -h "$BIN" | cut -f1))"

# ---------------------------------------------------------------------------
step "9/9 归档"
# ---------------------------------------------------------------------------
mkdir -p "$OPENCODE_BUILD_ARTIFACT_DIR"
cp "$BIN" "$OPENCODE_BUILD_ARTIFACT"
chmod 0755 "$OPENCODE_BUILD_ARTIFACT"
# 校验和写成「包根相对路径」，这样在包根执行 sha256sum -c artifact/opencode.sha256
# 可以直接通过（sha256sum 按 CWD 解析文件名，不会相对校验和文件所在目录）。
(cd "$OPENCODE_BUILD_ROOT" && sha256sum "artifact/opencode" > "$OPENCODE_BUILD_ARTIFACT_SHA256")
ok "已归档到 $OPENCODE_BUILD_ARTIFACT"
ok "校验和：$OPENCODE_BUILD_ARTIFACT_SHA256"
cat "$OPENCODE_BUILD_ARTIFACT_SHA256"

printf '\n%s构建完成%s —— 接下来跑：bash build/verify.sh\n' "$GREEN" "$NC"
