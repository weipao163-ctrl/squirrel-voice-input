#!/bin/bash
set -euo pipefail
[[ "$(id -u)" -ge 500 && "${2:-}" == "$HOME" && -d "$HOME" && ! -L "$HOME" ]] || { echo '拒绝以 root 或错配用户安装。' >&2; exit 2; }
source_app="$1"
script_directory="$(cd "$(dirname "$0")" && pwd)"
target="$HOME/Library/Input Methods/SquirrelEnhancedDev.app"
backup_root="$HOME/Library/Application Support/SquirrelEnhancedDev/install-backups"
for path in "$HOME/Library" "$HOME/Library/Input Methods" "$HOME/Library/Application Support" "$HOME/Library/Application Support/SquirrelEnhancedDev" "$backup_root" "$target"; do
  [[ ! -L "$path" ]] || { echo '拒绝符号链接安装路径，保留现场。' >&2; exit 2; }
done
/usr/bin/codesign --verify --deep --strict "$source_app"
identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")"
[[ "$identifier" == org.rime.inputmethod.SquirrelEnhanced.Development ]] || exit 2
if [[ -e "$target" ]]; then
  [[ -d "$target" ]] || { echo '目标身份冲突，保留现场。' >&2; exit 2; }
  old_identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")"
  # Upgrade only the previous isolated build whose identifier was not classified
  # as an input method by macOS. It receives the same recoverable app backup.
  [[ "$old_identifier" == "$identifier" || "$old_identifier" == org.rime.SquirrelEnhanced.Development ]] || { echo '目标身份冲突，保留现场。' >&2; exit 2; }
fi
source "$script_directory/app-update-preparation.sh"
prepare_development_app_update "$source_app" "$target"
source "$script_directory/app-install-transaction.sh"
install_development_app "$source_app" "$target" "$backup_root"
# Installer explicitly enables only this isolated source and never selects it.
if ! /usr/bin/open -g "$target"; then
  echo '程序文件已安装；系统尚未允许启动。请按安装完成页操作后重新登录。' >&2
fi
if ! "$target/Contents/MacOS/SquirrelEnhancedDev" --enable-input-source org.rime.inputmethod.SquirrelEnhanced.Development.Hans; then
  echo '程序文件已安装；输入源暂未启用。请重新登录后在系统设置中添加增强版。' >&2
fi
