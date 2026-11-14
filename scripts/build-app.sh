#!/bin/zsh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_dir/.build/swift-cache"

xcrun swift build --disable-sandbox -c release

app_dir="${BACKITUP_APP_DIR:-$repo_dir/dist/Backitup.app}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$repo_dir/.build/release/Backitup" "$app_dir/Contents/MacOS/Backitup"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/Resources/Backitup.icns" "$repo_dir/Resources/BackitupLogo.png" "$app_dir/Contents/Resources/"
chmod +x "$app_dir/Contents/MacOS/Backitup"
codesign --force --sign - "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
echo "$app_dir"
