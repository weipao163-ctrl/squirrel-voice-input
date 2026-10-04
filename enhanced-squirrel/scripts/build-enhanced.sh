#!/usr/bin/env bash
# Workspace build only. Does not install, select, deploy or restart any input method.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if [[ "$(uname -s)" != Darwin ]]; then echo '需要 macOS / Xcode；未执行构建。' >&2; exit 2; fi
command -v xcodebuild >/dev/null
xcodebuild -version >/dev/null 2>&1 || { echo '需要完整 Xcode；仅有 CLT 可用 scripts/build-clt.sh 做隔离开发验证。' >&2; exit 2; }
command -v swift >/dev/null
team="${ENHANCEMENT_TEAM_ID:-}"
identity="${ENHANCEMENT_SIGN_IDENTITY:--}"
if [[ -n "$team" && ! "$team" =~ ^[A-Z0-9]+$ ]]; then echo 'Team ID 无效' >&2; exit 2; fi
if [[ -n "$team" && "$identity" == - ]]; then echo '认证 XPC 必须有同一 Team 的真实签名身份；不能填 Team ID 后仅 ad-hoc。' >&2; exit 2; fi
if [[ ! -f lib/librime.1.dylib || ! -d Frameworks/Sparkle.framework ]]; then
  echo '先按 README 在工作副本执行 action-install.sh 下载固定上游依赖。' >&2; exit 2
fi
mkdir -p build/evidence
xcodebuild -version | tee build/evidence/xcode-version.txt
swift --version | tee build/evidence/swift-version.txt
swift test --package-path Enhancements 2>&1 | tee build/evidence/swift-tests.txt
swift build --package-path Enhancements -c release --product SquirrelVoiceHelper 2>&1 | tee build/evidence/helper-build.txt
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -mmacosx-version-min=13.0 \
  -I librime/src Enhancements/Native/LetterProbe.cpp \
  -Wl,-rpath,@executable_path/../Frameworks -o build/SquirrelLetterProbe \
  2>&1 | tee build/evidence/letter-probe-build.txt
helperbin="$(swift build --package-path Enhancements -c release --show-bin-path)/SquirrelVoiceHelper"
xcodebuild -project Squirrel.xcodeproj -scheme Squirrel -configuration Debug \
  -derivedDataPath build ENHANCEMENT_TEAM_ID="$team" CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/evidence/squirrel-build.txt
app="$root/build/Build/Products/Debug/SquirrelEnhancedDev.app"
[[ -d "$app" ]] || { echo '未生成预期开发 App；不继续打包。' >&2; exit 1; }
cp resources/EnhancedDefaultSquirrel.yaml "$app/Contents/SharedSupport/squirrel.yaml"
cp resources/Quick5/*.yaml "$app/Contents/SharedSupport/"
mkdir -p "$app/Contents/Resources/Licenses"
cp resources/Quick5/LICENSE "$app/Contents/Resources/Licenses/rime-quick-LGPL-3.0.txt"
cp resources/Quick5/GPL-3.0.txt resources/Quick5/AUTHORS resources/Quick5/UPSTREAM.json "$app/Contents/Resources/Licenses/"
helper="$app/Contents/Resources/SquirrelVoiceHelper.app"
mkdir -p "$helper/Contents/MacOS"
cp "$helperbin" "$helper/Contents/MacOS/SquirrelVoiceHelper"
cat > "$helper/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SquirrelVoiceHelper</string>
<key>CFBundleIdentifier</key><string>org.rime.SquirrelEnhanced.Development.VoiceHelper</string>
<key>CFBundleName</key><string>鼠须管增强设置开发版</string>
<key>CFBundleDisplayName</key><string>鼠须管增强设置开发版</string>
<key>LSUIElement</key><true/>
<key>CFBundleVersion</key><string>0.1.20</string><key>CFBundleShortVersionString</key><string>0.1.20</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSMicrophoneUsageDescription</key><string>仅在您明确按住说话或主动测试麦克风时采集音频。云测试和语音识别会发送音频至您选择并配置的语音服务。</string>
<key>SquirrelEnhancementTeamID</key><string>$team</string>
</dict></plist>
EOF
cp resources/letter_selection.lua "$app/Contents/Resources/letter_selection.lua"
mkdir -p "$app/Contents/Resources/LetterProbe"
cp resources/LetterProbe/letter_fixture.schema.yaml resources/LetterProbe/letter_fixture.dict.yaml "$app/Contents/Resources/LetterProbe/"
cp build/SquirrelLetterProbe "$app/Contents/MacOS/SquirrelLetterProbe"
codesign --force --options runtime --entitlements scripts/letter-probe.entitlements --sign "$identity" "$app/Contents/MacOS/SquirrelLetterProbe"
codesign --force --options runtime --entitlements scripts/helper.entitlements --sign "$identity" "$helper"
# Nested Helper already has its microphone entitlement. --deep with the parent
# entitlements would overwrite it and silently remove audio-input permission.
# Upstream dylibs/Sparkle retain their existing signatures.
codesign --force --options runtime --entitlements resources/Squirrel.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | tee build/evidence/signature.txt
# Real native fixture test in a fresh WORKSPACE build directory, never user Rime.
probe_tmp="$(mktemp -d "$root/build/letter-probe.XXXXXX")"
"$app/Contents/MacOS/SquirrelLetterProbe" "$app/Contents/Frameworks/librime.1.dylib" \
  "$app/Contents/Resources/LetterProbe" "$probe_tmp/runtime" abcdefghi true \
  | tee build/evidence/letter-probe-runtime.json
printf '构建路径：%s\n' "$app"
if [[ -z "$team" ]]; then echo 'ad-hoc 开发包：GUI 可独立打开；认证生产语音 IPC 关闭，不宣称语音集成可用。'; fi
