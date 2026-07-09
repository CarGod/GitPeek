#!/bin/bash
# 构建 GitPeek.app 并安装到 ~/Applications
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="GitPeek"
DEST="$HOME/Applications/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

BIN=".build/release/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
  echo "构建产物不存在: $BIN" >&2
  exit 1
fi

echo "==> 组装 app bundle"
# 若正在运行先退出，避免覆盖时报错
osascript -e 'tell application "GitPeek" to quit' >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 0.3

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS"
mkdir -p "$DEST/Contents/Resources"
cp "$BIN" "$DEST/Contents/MacOS/$APP_NAME"
cp Info.plist "$DEST/Contents/Info.plist"

# 优先用固定的自签名身份（指纹稳定，辅助功能授权不会因重建失效）；没有就退回 ad-hoc
IDENTITY="GitPeek Local"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "==> 用固定身份签名：$IDENTITY"
  codesign --force --sign "$IDENTITY" "$DEST"
else
  echo "==> ad-hoc 签名（未找到固定身份，重建后可能需重新授权辅助功能）"
  codesign --force --sign - "$DEST"
fi

echo "==> 已安装: $DEST"
echo "==> 启动"
open "$DEST"
echo "完成。若首次运行，请到「系统设置 › 隐私与安全性 › 辅助功能」勾选 GitPeek。"
