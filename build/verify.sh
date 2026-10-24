#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# 产物校验：证明二进制是纯 Bionic、零 glibc，且 Web UI 可用。
#
# 用法：
#   bash build/verify.sh [产物路径]
#   bash build/verify.sh            # 按 env.sh 的候选顺序自动找
#
# 退出码：0 = 全部通过；1 = 有检查项失败
# =============================================================================
set -Eeuo pipefail

PKG_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$PKG_ROOT/env.sh"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; DIM=$'\033[0;2m'; NC=$'\033[0m'
FAILURES=0

pass() { printf '  %s✔%s %s\n' "$GREEN" "$NC" "$1"; }
fail() { printf '  %s✘%s %s\n' "$RED" "$NC" "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  %s▲%s %s\n' "$YELLOW" "$NC" "$1"; }
step() { printf '\n%s== %s%s\n' "$DIM" "$1" "$NC"; }

# ---------------------------------------------------------------------------
# 定位产物
# ---------------------------------------------------------------------------
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  while IFS= read -r c; do
    [ -n "$c" ] && [ -f "$c" ] && { TARGET="$c"; break; }
  done < <(opencode_artifact_candidates)
fi
if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
  echo "找不到产物。用法：bash build/verify.sh <产物路径>" >&2
  exit 1
fi
TARGET="$(readlink -f -- "$TARGET")"

echo "产物：$TARGET"
echo "大小：$(du -h "$TARGET" | cut -f1)"

RUNNABLE=0
if [ ! -x "$TARGET" ]; then
  echo "警告：产物缺少可执行位（将尝试补足以便自检）" >&2
  chmod +x "$TARGET" 2>/dev/null || true
fi
[ -x "$TARGET" ] && RUNNABLE=1 || RUNNABLE=0

# ---------------------------------------------------------------------------
# 1. 校验和
# ---------------------------------------------------------------------------
step "1/7 SHA256"
ACTUAL="$(sha256sum "$TARGET" | cut -d' ' -f1)"
echo "  实测：$ACTUAL"
if [ -f "$OPENCODE_BUILD_ARTIFACT_SHA256" ]; then
  EXPECTED="$(cut -d' ' -f1 < "$OPENCODE_BUILD_ARTIFACT_SHA256" | head -1)"
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    pass "与 artifact/opencode.sha256 一致"
  else
    fail "与 artifact/opencode.sha256 不一致（期望 $EXPECTED）"
  fi
else
  warn "缺少 $OPENCODE_BUILD_ARTIFACT_SHA256，跳过比对"
fi

# ---------------------------------------------------------------------------
# 2. ELF 头
# ---------------------------------------------------------------------------
step "2/7 ELF 架构与链接器"
READELF=''
for name in greadelf readelf llvm-readelf aarch64-linux-android-readelf; do
  if command -v "$name" >/dev/null 2>&1 && "$name" --version >/dev/null 2>&1; then READELF="$name"; break; fi
done
if [ -z "$READELF" ]; then
  fail "找不到 ELF 工具（greadelf/readelf/llvm-readelf）"
else
  HEADER="$("$READELF" -hW -- "$TARGET")"
  PROGRAMS="$("$READELF" -lW -- "$TARGET")"
  DYNAMIC="$("$READELF" -dW -- "$TARGET")"
  VERSIONS="$("$READELF" -VW -- "$TARGET")"

  grep -q 'ELF64' <<< "$HEADER" && pass "ELF64" || fail "不是 ELF64"
  grep -q 'AArch64' <<< "$HEADER" && pass "AArch64" || fail "不是 AArch64"
  grep -q '\[Requesting program interpreter: /system/bin/linker64\]' <<< "$PROGRAMS" \
    && pass "解释器 = /system/bin/linker64（Android Bionic）" \
    || fail "解释器不是 /system/bin/linker64"
  grep -q 'DYN' <<< "$HEADER" && pass "PIE / DYN" || warn "不是 DYN（静态链接的 PIE 除外）"

  NEEDED="$(grep 'NEEDED' <<< "$DYNAMIC" | sed -n 's/.*\[\(.*\)\]/\1/p' | sort | tr '\n' ' ')"
  echo "  NEEDED：$NEEDED"
  BAD=""
  for n in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 libutil.so.1 ld-linux ld-musl; do
    grep -qw -- "$n" <<< "$NEEDED" && BAD="$BAD $n"
  done
  [ -z "$BAD" ] && pass "主程序无 glibc/musl 依赖" || fail "主程序含 glibc/musl 依赖：$BAD"
fi

# ---------------------------------------------------------------------------
# 3. GLIBC_ 版本符号
# ---------------------------------------------------------------------------
# 注意：不要用「全文件 grep libc.so.6」来判断 —— Bun 运行时自己的字符串表里
# 就有一堆 glibc 字面量（位于 UTF-16 / fts5 / randomUUIDv5 等字符串之间），
# 那是数据不是依赖，会误报。权威判据是：
#   - readelf -d 的 NEEDED 列表（主程序）
#   - readelf -V 的版本符号（GLIBC_xxx）
#   - 每个内嵌 ELF 切片单独判定（见第 4 步）
step "3/7 GLIBC_ 版本符号"
if [ -n "$READELF" ]; then
  GLIBC_COUNT="$(grep -c 'GLIBC_' <<< "$VERSIONS" || true)"
  echo "  GLIBC_ 版本符号：$GLIBC_COUNT"
  if [ "${GLIBC_COUNT:-0}" -eq 0 ]; then
    pass "主程序无 GLIBC_ 版本符号"
  else
    fail "主程序含 $GLIBC_COUNT 个 GLIBC_ 版本符号"
    grep 'GLIBC_' <<< "$VERSIONS" | head -10 | sed 's/^/    /'
  fi
else
  warn "没有 ELF 工具，跳过"
fi

# ---------------------------------------------------------------------------
# 4. 内嵌 ELF 逐个检查
# ---------------------------------------------------------------------------
step "4/7 内嵌 ELF 依赖扫描"
SCANNER_OK=0
if command -v bun >/dev/null 2>&1; then
  RUNNER="bun"
elif command -v node >/dev/null 2>&1; then
  RUNNER="node"
else
  RUNNER=""
fi
if [ -n "$RUNNER" ]; then
  # --expect：要求内嵌的 bun-pty / pty 守护进程与我们的 Bionic 资产逐字节一致，
  # 这样就不只是「没有 glibc」，而是「确实是我们放进来的那个 Bionic 版」。
  if "$RUNNER" "$PKG_ROOT/build/scan-elf.ts" "$TARGET" \
      --expect "$OPENCODE_BUN_PTY_SHA256:bun-pty (Bionic)" \
      --expect "$OPENCODE_PTY_SERVICE_SHA256:opencode-pty 守护进程 (静态)"; then
    pass "内嵌 ELF 均为 Bionic，且关键资产 sha256 匹配"
    SCANNER_OK=1
  else
    fail "内嵌 ELF 检查未通过"
  fi
else
  warn "没有 bun/node，跳过内嵌 ELF 扫描"
fi

# ---------------------------------------------------------------------------
# 5. 版本与自检
# ---------------------------------------------------------------------------
step "5/7 实机运行"
if [ "$RUNNABLE" -ne 1 ]; then
  fail "产物不可执行（缺少 x 位）：$TARGET"
else
  if VERSION_OUT="$("$TARGET" --version 2>/dev/null)"; then
    echo "  --version → ${VERSION_OUT}"
    if [ -n "${OPENCODE_VERSION:-}" ]; then
      if [[ "$VERSION_OUT" == *"$OPENCODE_VERSION"* ]]; then
        pass "可执行（opencode v${OPENCODE_VERSION}）"
      else
        fail "版本不符（期望包含 v${OPENCODE_VERSION}，实际：${VERSION_OUT}）"
      fi
    else
      pass "可执行"
    fi
  else
    echo "  --version → <执行失败>"
    fail "无法执行 $TARGET --version"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Web UI
# ---------------------------------------------------------------------------
step "6/7 Web UI"
PORT="${OPENCODE_VERIFY_PORT:-40999}"
LOG="$(mktemp "$HOME/.opencode-verify.XXXXXX.log")"
SERVE_PID=""
cleanup() {
  if [ -n "${SERVE_PID:-}" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  rm -f "${LOG:-}" "$HOME/.opencode-verify-root.html" "$HOME/.opencode-verify-bundle.js"
}
trap cleanup EXIT
if [ "${RUNNABLE:-0}" -ne 1 ]; then
  warn "产物不可执行，跳过 Web UI"
  ROOT_CODE=""
else
  "$TARGET" serve --port "$PORT" >"$LOG" 2>&1 &
  SERVE_PID=$!

  ROOT_CODE=""
  for _ in $(seq 1 40); do
    ROOT_CODE="$(curl -s -o "$HOME/.opencode-verify-root.html" -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)"
    [ "$ROOT_CODE" = "200" ] && break
    sleep 0.5
  done

  if [ -z "${ROOT_CODE:-}" ]; then
    fail "未能启动或访问 Web UI"
    [ -f "$LOG" ] && { echo "--- serve 日志 ---"; tail -30 "$LOG"; }
  elif [ "$ROOT_CODE" != "200" ]; then
    fail "根路径 HTTP $ROOT_CODE（期望 200）"
    [ -f "$LOG" ] && { echo "--- serve 日志 ---"; tail -30 "$LOG"; }
  else
    pass "根路径 HTTP 200"
    HTML="$HOME/.opencode-verify-root.html"
    # 从 HTML 里抠出所有 /_assets/... 资源，逐个检查
    ASSETS="$(grep -oE '/_assets/[A-Za-z0-9._/-]+' "$HTML" | sort -u)"
    TOTAL=0; BAD=0
    for a in $ASSETS; do
      TOTAL=$((TOTAL + 1))
      CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$a" 2>/dev/null || echo 000)"
      [ "$CODE" = "200" ] || { BAD=$((BAD + 1)); echo "    ✘ $a → $CODE"; }
    done
    if [ "$TOTAL" -gt 0 ] && [ "$BAD" -eq 0 ]; then
      pass "$TOTAL 个入口资源全部 HTTP 200"
    else
      fail "入口资源 $BAD/$TOTAL 个非 200"
    fi
    rm -f "$HTML"
  fi
fi

# ---------------------------------------------------------------------------
# 7. 功能点抽查：回车行为 + 中文文案
# ---------------------------------------------------------------------------
step "7/7 功能点抽查（Web UI 产物内）"
if [ "${ROOT_CODE:-}" = "200" ] && [ "${RUNNABLE:-0}" -eq 1 ]; then
  # 把入口 HTML 里引用的 JS chunk 全部拉下来拼成一份，一次性扫描。
  BUNDLE="$HOME/.opencode-verify-bundle.js"
  : > "$BUNDLE"
  curl -s "http://127.0.0.1:$PORT/" \
    | grep -oE '/_assets/[A-Za-z0-9._/-]+\.js' | sort -u \
    | while IFS= read -r js; do
        curl -s "http://127.0.0.1:$PORT$js" >> "$BUNDLE"
      done

  if [ ! -s "$BUNDLE" ]; then
    fail "未能拉取 Web UI 资源包"
  else
    if grep -q 'enterBehavior' "$BUNDLE"; then
      pass "产物内含 enterBehavior 逻辑"
    else
      fail "产物内未命中 enterBehavior（回车行为可能缺失）"
    fi
    if grep -q '回车发送' "$BUNDLE"; then
      pass "产物内含中文文案「回车发送」"
    else
      fail "产物内未命中中文文案「回车发送」"
    fi
  fi
  rm -f "$BUNDLE"
else
  fail "Web UI 未就绪，无法抽查功能点"
fi

# ---------------------------------------------------------------------------
# 结论
# ---------------------------------------------------------------------------
echo
if [ "$FAILURES" -eq 0 ]; then
  printf '%s✔ 全部检查通过%s\n' "$GREEN" "$NC"
  exit 0
else
  printf '%s✘ %d 项检查失败%s\n' "$RED" "$FAILURES" "$NC"
  exit 1
fi
