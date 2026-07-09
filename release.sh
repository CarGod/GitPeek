#!/bin/bash
# 构建 → Developer ID 签名(hardened runtime) → 公证 → staple → 打包成 .dmg
# 前置：① 钥匙串里有 "Developer ID Application" 证书
#      ② 已用 notarytool 存好凭据 profile（默认名 GitPeek）：
#         xcrun notarytool store-credentials "GitPeek" \
#           --apple-id <你的AppleID邮箱> --team-id 34MS36N7HF --password <App专用密码>
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="GitPeek"
NOTARY_PROFILE="${NOTARY_PROFILE:-GitPeek}"
DIST="dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo 0.1.0)"

echo "==> 查找 Developer ID Application 签名身份"
SIGN_ID="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')"
if [[ -z "${SIGN_ID:-}" ]]; then
  echo "✗ 没有 'Developer ID Application' 证书。" >&2
  echo "  在 Xcode ▸ Settings ▸ Accounts ▸ (选账号) Manage Certificates ▸ + ▸ Developer ID Application 创建。" >&2
  exit 1
fi
echo "    使用: $SIGN_ID"

echo "==> 编译 release"
swift build -c release
BIN=".build/release/$APP_NAME"

echo "==> 组装 app bundle"
rm -rf "$DIST"; mkdir -p "$DIST"
APPDIR="$DIST/$APP_NAME.app"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP_NAME"
cp Info.plist "$APPDIR/Contents/Info.plist"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APPDIR/Contents/Resources/AppIcon.icns"

echo "==> 签名（hardened runtime + entitlements + 时间戳）"
codesign --force --options runtime --timestamp \
  --entitlements Entitlements.plist \
  --sign "$SIGN_ID" "$APPDIR"
codesign --verify --strict --verbose=2 "$APPDIR"

echo "==> 打 .dmg"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGING="$DIST/staging"
mkdir -p "$STAGING"
cp -R "$APPDIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

echo "==> 提交公证（会等待结果，约 1-5 分钟）"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> staple 装订公证票据"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "✓ dmg 已签名 + 公证 + staple: $DMG"

# ── 发布到 GitHub Release（幂等）───────────────────────────────
# 版本号取自 Info.plist 的 CFBundleShortVersionString；改版本 = 改那里再重跑本脚本。
TAG="v$VERSION"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "==> 发布 GitHub Release $TAG"
  # 确保 tag 存在并推送
  git rev-parse "$TAG" >/dev/null 2>&1 || git tag -a "$TAG" -m "GitPeek $VERSION"
  git push origin "$TAG" 2>/dev/null || true
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" --clobber
    echo "    已更新已存在 Release 的 dmg 附件"
  else
    gh release create "$TAG" "$DMG" \
      --title "GitPeek $VERSION" \
      --notes "GitPeek $VERSION — 已签名 + Apple 公证的 .dmg，下载双击拖进 Applications 即可（无 Gatekeeper 警告）。详见 README。" \
      --verify-tag
    echo "    已创建 Release"
  fi
  echo -n "    "; gh release view "$TAG" --json url --jq .url
else
  echo "（未检测到已登录的 gh，跳过自动发布；dmg 在 $DMG，可手动 gh release create $TAG \"$DMG\"）"
fi

echo
echo "✓ 全部完成。别人从 Releases 页下载 dmg，双击拖进 Applications 即可，无 Gatekeeper 警告。"
