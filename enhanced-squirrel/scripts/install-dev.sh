#!/usr/bin/env bash
# Explicit user-owned installation only. Dry-run unless --apply is passed.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
apply=0
if [[ "${1:-}" == --apply ]]; then apply=1; shift; fi
source_app="${1:-$root/build/Build/Products/Debug/SquirrelEnhancedDev.app}"
if [[ "$source_app" != /* ]]; then source_app="$PWD/$source_app"; fi
target="$HOME/Library/Input Methods/SquirrelEnhancedDev.app"
echo "只安装开发版：$source_app -> $target"
echo '不替换 Squirrel.app，不改 ~/Library/Rime，不自动启用/切换/重启输入源。'
if [[ "$apply" == 0 ]]; then echo '干跑；明确授权安装后使用 --apply。'; exit 0; fi
[[ "$(uname -s)" == Darwin && -d "$source_app" ]] || { echo '需要真实 macOS 构建产物。' >&2; exit 2; }
codesign --verify --deep --strict "$source_app"
id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")
[[ "$id" == org.rime.inputmethod.SquirrelEnhanced.Development ]] || { echo '拒绝安装非开发包' >&2; exit 2; }
if pgrep -f '^.*/SquirrelEnhancedDev.app/Contents/(MacOS/|Resources/SquirrelVoiceHelper.app/Contents/MacOS/)' >/dev/null; then
  echo '开发版进程正在运行，请自行切换到其他输入源并退出；不自动终止。' >&2; exit 2
fi
if [[ -d "$target" ]]; then
  oldid=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")
  [[ "$oldid" == "$id" || "$oldid" == org.rime.SquirrelEnhanced.Development ]] || { echo '目标身份冲突，保留现场' >&2; exit 2; }
fi
source "$root/scripts/app-install-transaction.sh"
install_development_app "$source_app" "$target" "$HOME/Library/Application Support/SquirrelEnhancedDev/install-backups"
