#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# 生成可分发的离线包（Release 资产）
#
# 用法：
#   bash build/package-release.sh [输出路径]
#   默认：$HOME/opencode.zip
#
# 内容与仓库布局一致，但不包含 .git、构建树、临时文件：
#   README.md .gitignore env.sh artifact/ installer/ build/ upstream/ docs/
#
# 该脚本只负责打包，不重新构建；请先执行 build/build.sh 与 build/verify.sh。
# =============================================================================
set -Eeuo pipefail

PKG_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HOME/opencode.zip}"
case "$OUT" in
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac

command -v zip >/dev/null 2>&1 || { echo "缺少 zip 命令。pkg install zip" >&2; exit 1; }
[ -f "$PKG_ROOT/artifact/opencode" ] || { echo "缺少 artifact/opencode，请先构建" >&2; exit 1; }

STAGE="$(mktemp -d "$HOME/.opencode-release.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
DEST="$STAGE/opencode-build"
mkdir -p -- "$DEST"

for entry in README.md .gitignore env.sh artifact installer build upstream docs; do
  [ -e "$PKG_ROOT/$entry" ] || { echo "缺少打包项：$entry" >&2; exit 1; }
  cp -a -- "$PKG_ROOT/$entry" "$DEST/"
done

# 二进制必须可执行；zip 会保留 Unix 权限位。
chmod 755 -- "$DEST/artifact/opencode"
# 防止把上一次的发布包或临时文件带进去。
rm -f -- "$DEST/opencode.zip"

rm -f -- "$OUT"
(cd "$STAGE" && zip -r -q "$OUT" opencode-build)
echo "已生成：$OUT"
echo "大小：$(du -h "$OUT" | cut -f1)"
sha256sum -- "$OUT"
