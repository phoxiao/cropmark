#!/bin/zsh
# 发布打包：Release 构建 → 签名 →（可选）公证装订 → dmg / zip / 校验和 → dist/
# 用法：make release            用本机证书签名，不公证
#       NOTARY_PROFILE=xxx make release   用 notarytool 已存的凭据公证
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DERIVED=${DERIVED:-$HOME/Library/Caches/CropmarkBuild}
APP="$DERIVED/Build/Products/Release/Cropmark.app"
DIST="$ROOT/dist"
VERSION=$(grep -E '^\s*CFBundleShortVersionString:' "$ROOT/project.yml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
[[ -n "$VERSION" ]] || { echo "读不到版本号"; exit 1; }
NAME="Cropmark-$VERSION"

echo "==> Release 构建 $VERSION"
cd "$ROOT"
xcodegen generate >/dev/null
xcodebuild -project Cropmark.xcodeproj -scheme Cropmark -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build 2>&1 | tee "$DERIVED/release-build.log" | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
grep -q "BUILD SUCCEEDED" "$DERIVED/release-build.log"
if [[ -d "$APP/Contents/PlugIns" ]] && [[ -n "$(ls -A "$APP/Contents/PlugIns")" ]]; then
  echo "Release 包里混入了插件（测试包？）："; ls "$APP/Contents/PlugIns"; exit 1
fi

echo "==> 签名"
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
SIGN_ID=$(echo "$IDENTITIES" | awk '/Developer ID Application/ {print $2; exit}')
TIMESTAMP=()
if [[ -n "$SIGN_ID" ]]; then
  KIND="Developer ID"; TIMESTAMP=(--timestamp)
else
  SIGN_ID=$(echo "$IDENTITIES" | awk '/Apple Development/ {print $2; exit}')
  if [[ -n "$SIGN_ID" ]]; then KIND="Apple Development（未公证，用户首次打开需放行）"; else SIGN_ID="-"; KIND="ad-hoc（每次重编译权限都会失效）"; fi
fi
codesign --force --deep --options runtime "${TIMESTAMP[@]}" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "    已用 $KIND 签名"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> 公证（profile: $NOTARY_PROFILE）"
  TMPZIP=$(mktemp -d)/$NAME-notary.zip
  ditto -c -k --keepParent "$APP" "$TMPZIP"
  xcrun notarytool submit "$TMPZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
else
  echo "    未公证：设置 NOTARY_PROFILE 环境变量可自动公证"
fi

echo "==> 打包到 dist/"
rm -rf "$DIST"; mkdir -p "$DIST"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Cropmark" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg"
ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
ls -la "$DIST"
echo "==> 完成：$DIST/$NAME.dmg"
