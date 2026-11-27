#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "错误：当前 Mac 未安装完整版 Xcode，无法在本地编译 iPhoneOS ARM64 二进制。"
  echo "请选择以下任一方式生成 PaoManLeMa.ipa："
  echo "  1) 从 Mac App Store 安装 Xcode 后重新运行 ./build_ipa.sh"
  echo "  2) 将本目录推送到任意 GitHub 仓库（公开或私有均可），GitHub Actions 会自动在云端 macOS 编译并生成 PaoManLeMa.ipa 供下载自签。"
  exit 1
fi

rm -rf build PaoManLeMa.ipa

xcodebuild \
  -project PaoManLeMa.xcodeproj \
  -scheme PaoManLeMa \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  AD_HOC_CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p build/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/PaoManLeMa.app build/Payload/
(cd build && zip -qry ../PaoManLeMa.ipa Payload)

echo "打包完成：$(pwd)/PaoManLeMa.ipa"
ls -lh PaoManLeMa.ipa
