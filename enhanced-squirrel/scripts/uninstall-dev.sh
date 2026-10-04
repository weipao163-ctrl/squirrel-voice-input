#!/usr/bin/env bash
set -euo pipefail
target="$HOME/Library/Input Methods/SquirrelEnhancedDev.app"
echo "只移除开发 App：$target"
echo '默认保留开发设置、Keychain、开发 Rime 目录及全部正式版词库；不回写任何用户 custom。'
[[ "${1:-}" == --apply ]] || { echo '干跑；使用 --apply 才执行。'; exit 0; }
[[ "$(uname -s)" == Darwin ]] || exit 2
if pgrep -f '^.*/SquirrelEnhancedDev.app/Contents/(MacOS/|Resources/SquirrelVoiceHelper.app/Contents/MacOS/)' >/dev/null; then
  echo '先手动切换输入源并退出开发版；本脚本不自动终止。' >&2; exit 2
fi
[[ -d "$target" ]] || exit 0
lock="$target.install-lock"
mkdir "$lock" 2>/dev/null || { echo "安装/卸载事务锁已存在，保留现场：$lock" >&2; exit 2; }
trap 'rmdir "$lock"' EXIT
id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")
[[ "$id" == org.rime.inputmethod.SquirrelEnhanced.Development || "$id" == org.rime.SquirrelEnhanced.Development ]] || { echo '身份冲突，不删除。' >&2; exit 2; }
mkdir -p "$HOME/Library/Application Support/SquirrelEnhancedDev/install-backups"
mv "$target" "$HOME/Library/Application Support/SquirrelEnhancedDev/install-backups/uninstalled-$(date +%Y%m%d-%H%M%S)-$$.app"
echo '开发包已移至可恢复备份。请手动移除系统设置中的开发输入源；正式版及后续 custom 修改未变。'
