#!/usr/bin/env bash
# Workspace-only arm64 validation build with Command Line Tools. No installation,
# input-source registration, current-user Rime deployment or microphone access.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
[[ "$(uname -s)" == Darwin ]] || { echo '需要 macOS。' >&2; exit 2; }
runtime="${SQUIRREL_RUNTIME_APP:-}"
sdk="$(python3 "$root/../tools/macos_sdk.py")"
if [[ -n "$runtime" ]]; then
  rime_library="$runtime/Contents/Frameworks/librime.1.dylib"
  rime_plugins="$runtime/Contents/Frameworks/rime-plugins"
  shared_support="$runtime/Contents/SharedSupport"
else
  rime_library="$root/lib/librime.1.dylib"
  rime_plugins="$root/lib/rime-plugins"
  shared_support="$root/data/plum"
fi
[[ -d "$sdk" && -f "$rime_library" && -d "$rime_plugins" && -d "$shared_support" && -d Frameworks/Sparkle.framework ]] || {
  echo '先运行 scripts/prepare-dependencies.sh 准备公开运行依赖；见仓库构建说明。' >&2; exit 2;
}
mkdir -p "$root/../evidence"
local_certificate_sha1=''
if [[ "${ENHANCEMENT_LOCAL_SIGNING:-0}" == 1 ]]; then
  source "$root/scripts/local-signing.sh"
  prepare_local_signing
fi
export local_certificate_sha1
mkdir -p build/evidence
python3 "$root/../tools/macos_build_provenance.py" start "$sdk"
swift build --package-path Enhancements --build-system native --sdk "$sdk" \
  --scratch-path build/swift-clt -j 4 --product SquirrelVoiceHelper \
  2>&1 | tee build/evidence/clt-helper.txt
bins="$(swift build --package-path Enhancements --build-system native --sdk "$sdk" --scratch-path build/swift-clt --show-bin-path)"
stage="$(mktemp -d "$root/build/clt-stage.XXXXXX")"
app="$stage/SquirrelEnhancedDev.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
arch="$(uname -m)"
xcrun swiftc -swift-version 5 -module-name Squirrel -sdk "$sdk" -target "$arch-apple-macos13.0" \
  -I "$bins/Modules" -F Frameworks -I librime/src -I librime/include \
  -import-objc-header sources/Squirrel-Bridging-Header.h -enable-bare-slash-regex \
  sources/*.swift "$bins"/EnhancementCore.build/*.swift.o "$bins"/EnhancementIPC.build/*.swift.o "$bins"/EnhancementUI.build/*.swift.o \
  "$rime_library" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app/Contents/MacOS/SquirrelEnhancedDev" 2>&1 | tee build/evidence/clt-frontend.txt
cp "$rime_library" "$app/Contents/Frameworks/"
cp -R "$rime_plugins" "$app/Contents/Frameworks/"
cp -R Frameworks/Sparkle.framework "$app/Contents/Frameworks/"
mkdir -p "$app/Contents/SharedSupport"
cp -R "$shared_support/." "$app/Contents/SharedSupport/"
if [[ -z "$runtime" ]]; then
  cp -R data/opencc "$app/Contents/SharedSupport/"
fi
cp resources/EnhancedDefaultSquirrel.yaml "$app/Contents/SharedSupport/squirrel.yaml"
cp resources/Quick5/*.yaml "$app/Contents/SharedSupport/"
cp resources/rime.pdf resources/letter_selection.lua "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/Licenses"
cp LICENSE.txt "$app/Contents/Resources/Licenses/Squirrel-GPL-3.0.txt"
cp Enhancements/LICENSE "$app/Contents/Resources/Licenses/Enhancements-MIT.txt"
cp librime/LICENSE "$app/Contents/Resources/Licenses/librime-LICENSE.txt"
cp third-party/Sparkle-LICENSE.txt "$app/Contents/Resources/Licenses/"
cp resources/Quick5/LICENSE "$app/Contents/Resources/Licenses/rime-quick-LGPL-3.0.txt"
cp resources/Quick5/GPL-3.0.txt resources/Quick5/AUTHORS resources/Quick5/UPSTREAM.json "$app/Contents/Resources/Licenses/"
cp -R resources/LetterProbe "$app/Contents/Resources/"
helper="$app/Contents/Resources/SquirrelVoiceHelper.app"
mkdir -p "$helper/Contents/MacOS"
cp "$bins/SquirrelVoiceHelper" "$helper/Contents/MacOS/"
if [[ -n "$runtime" && -f "$runtime/Contents/Resources/RimeIcon.icns" ]]; then
  cp "$runtime/Contents/Resources/RimeIcon.icns" build/runtime-icon.icns
fi
python3 - "$app" "$root" <<'PY'
import json, os, plistlib, sys
from pathlib import Path
app,root=map(Path,sys.argv[1:])
info=plistlib.loads((root/'resources/Info.plist').read_bytes())
info.update(CFBundleIdentifier='org.rime.inputmethod.SquirrelEnhanced.Development',
            CFBundleExecutable='SquirrelEnhancedDev',CFBundleVersion='0.1.23',
            CFBundleShortVersionString='0.1.23',CFBundleSupportedPlatforms=['MacOSX'],
            LSMinimumSystemVersion='13.0',SquirrelEnhancementTeamID='',SquirrelEnhancementCertificateSHA1=os.environ['local_certificate_sha1'])
# Team ID is never fabricated; local trust is an exact certificate pin.
icon=root/'build/runtime-icon.icns'
if icon.exists():
    (app/'Contents/Resources/RimeIcon.icns').write_bytes(icon.read_bytes())
    info['CFBundleIconFile']='RimeIcon.icns'
else:
    info.pop('CFBundleIconFile',None)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
helper={'CFBundleIdentifier':'org.rime.SquirrelEnhanced.Development.VoiceHelper',
 'CFBundleExecutable':'SquirrelVoiceHelper','CFBundleName':'鼠须管增强设置开发版',
 'CFBundleDisplayName':'鼠须管增强设置开发版','LSUIElement':True,
 'CFBundlePackageType':'APPL','CFBundleVersion':'0.1.23','CFBundleShortVersionString':'0.1.23',
 'LSMinimumSystemVersion':'13.0','SquirrelEnhancementTeamID':'',
 'SquirrelEnhancementCertificateSHA1':os.environ['local_certificate_sha1'],
 'NSMicrophoneUsageDescription':'仅在明确按住说话或主动测试时采集；云识别会向您选择并配置的语音服务发送音频。'}
(app/'Contents/Resources/SquirrelVoiceHelper.app/Contents/Info.plist').write_bytes(plistlib.dumps(helper))
# Compile the existing flat string catalogs for a complete CLT bundle.
for name in ['Localizable','InfoPlist']:
    catalog=json.loads((root/f'resources/{name}.xcstrings').read_text())
    tables={catalog['sourceLanguage']:{}}
    for key,record in catalog['strings'].items():
        tables[catalog['sourceLanguage']][key]=key
        for locale,value in record.get('localizations',{}).items():
            if 'stringUnit' not in value:
                raise RuntimeError('Unsupported string catalog variation: '+key)
            tables.setdefault(locale,{})[key]=value['stringUnit']['value']
    for locale,table in tables.items():
        destination=app/f'Contents/Resources/{locale}.lproj'
        destination.mkdir(exist_ok=True)
        (destination/f'{name}.strings').write_bytes(plistlib.dumps(table,fmt=plistlib.FMT_BINARY))
if (app/'Contents/Resources/RimeIcon.icns').exists():
    helper_resources=app/'Contents/Resources/SquirrelVoiceHelper.app/Contents/Resources'
    helper_resources.mkdir(exist_ok=True)
    (helper_resources/'RimeIcon.icns').write_bytes((app/'Contents/Resources/RimeIcon.icns').read_bytes())
    helper['CFBundleIconFile']='RimeIcon.icns'
    (app/'Contents/Resources/SquirrelVoiceHelper.app/Contents/Info.plist').write_bytes(plistlib.dumps(helper))

PY
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -isysroot "$sdk" -mmacosx-version-min=13.0 \
  -I librime/src Enhancements/Native/LetterProbe.cpp -o "$app/Contents/MacOS/SquirrelLetterProbe"
# Remove debug-only object/module paths from distributable executables before
# signing. Keep runtime symbols and Objective-C/Swift metadata intact.
/usr/bin/strip -S "$app/Contents/MacOS/SquirrelEnhancedDev" "$helper/Contents/MacOS/SquirrelVoiceHelper"
# Public librime archives can contain unsigned libraries. Sign the copied
# runtime components before signing their parent; do not alter downloaded files.
while IFS= read -r -d '' library; do
  codesign --force --sign - "$library"
done < <(find "$app/Contents/Frameworks" -type f -name '*.dylib' -print0)
# Sign nested custom components first; never re-sign Helper with parent entitlements.
if [[ -n "$local_certificate_sha1" ]]; then
  sign_local_code "$app/Contents/MacOS/SquirrelLetterProbe" scripts/letter-probe.entitlements
  sign_local_code "$helper" scripts/helper.entitlements
  sign_local_code "$app" resources/Squirrel.entitlements
else
  codesign --force --sign - --options runtime --entitlements scripts/letter-probe.entitlements "$app/Contents/MacOS/SquirrelLetterProbe"
  codesign --force --sign - --options runtime --entitlements scripts/helper.entitlements "$helper"
  codesign --force --sign - --options runtime --entitlements resources/Squirrel.entitlements "$app"
fi
codesign --verify --deep --strict "$app" 2>&1 | tee build/evidence/clt-signature.txt
mkdir -p build/CLT
if [[ -e build/CLT/SquirrelEnhancedDev.app ]]; then
  mv build/CLT/SquirrelEnhancedDev.app "build/CLT/SquirrelEnhancedDev.previous.$(date +%Y%m%d%H%M%S).app"
fi
mv "$app" build/CLT/
rmdir "$stage"
python3 "$root/../tools/macos_build_provenance.py" complete "$root/build/CLT/SquirrelEnhancedDev.app"
echo "构建候选：$root/build/CLT/SquirrelEnhancedDev.app"
if [[ -n "$local_certificate_sha1" ]]; then
  echo '本机 arm64、本地证书签名、双向证书绑定 IPC；未经 Apple 公证。没有安装或切换输入源。'
else
  echo '仅本机架构、ad-hoc 开发候选；认证生产 IPC 未启用。没有安装或切换输入源。'
fi
