#!/bin/bash
# Root owns the system app and registers its system-wide input-source metadata.
# User enablement, IMK and process operations run as the logged-in user; personal
# data stays in that user's profile.
set -euo pipefail
[[ "$(id -u)" == 0 && "$#" == 4 ]] || exit 2
source_app="$1"; account="$2"; account_uid="$3"; account_home="$4"
script_directory="$(cd "$(dirname "$0")" && pwd)"
[[ "$account" =~ ^[A-Za-z0-9_.-]+$ && "$account_uid" =~ ^[0-9]+$ && "$account_uid" -ge 500 &&
   "$(id -u "$account")" == "$account_uid" && "$account_home" == /* &&
   "$account_home" != *$'\n'* && -d "$account_home" && ! -L "$account_home" &&
   "$(/usr/bin/stat -f '%u' "$account_home")" == "$account_uid" ]] || exit 2
target='/Library/Input Methods/SquirrelEnhancedDev.app'
backup_root='/Library/Application Support/SquirrelEnhancedDev/install-backups'
user_app="$account_home/Library/Input Methods/SquirrelEnhancedDev.app"
user_support="$account_home/Library/Application Support/SquirrelEnhancedDev"
for path in '/Library/Input Methods' '/Library/Application Support/SquirrelEnhancedDev' "$backup_root" "$target"; do
  [[ ! -L "$path" ]] || { echo '拒绝符号链接系统安装路径。' >&2; exit 2; }
done
[[ -d "$source_app" && ! -L "$source_app" ]] || exit 2
/usr/bin/codesign --verify --deep --strict "$source_app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")" == org.rime.inputmethod.SquirrelEnhanced.Development ]] || exit 2
for path in "$target" "$user_app"; do
  if [[ -e "$path" ]]; then
    [[ -d "$path" && ! -L "$path" &&
      "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$path/Contents/Info.plist")" == org.rime.inputmethod.SquirrelEnhanced.Development ]] || exit 2
  fi
done
as_console_user() { /bin/launchctl asuser "$account_uid" /usr/bin/sudo -H -u "$account" "$@"; }
retired=''
resume_after_failure() {
  local status=$?
  if [[ "$status" != 0 ]]; then
    if [[ -n "$retired" && -d "$retired" && ! -e "$user_app" && ! -e "$target" ]]; then
      as_console_user /bin/mv "$retired" "$user_app" || true
      as_console_user "$user_app/Contents/MacOS/SquirrelEnhancedDev" --register-input-source || true
    fi
    for existing in "$target" "$user_app"; do
      if [[ -d "$existing" && ! -L "$existing" ]]; then
        as_console_user /usr/bin/open -g "$existing" || true
        break
      fi
    done
  fi
  exit "$status"
}
trap resume_after_failure EXIT
# The current installed executable understands its own path and holds no
# composition after cooperative termination. The old Helper is also drained.
for path in "$user_app" "$target"; do
  if [[ -d "$path" ]]; then
    as_console_user "$path/Contents/MacOS/SquirrelEnhancedDev" --quit --installed-app-path "$path"
  fi
done
for attempt in {1..100}; do
  if ! /usr/bin/pgrep -u "$account_uid" -f '^.*/SquirrelEnhancedDev.app/Contents/(MacOS/|Resources/SquirrelVoiceHelper.app/Contents/MacOS/)' >/dev/null; then break; fi
  /bin/sleep 0.1
done
if /usr/bin/pgrep -u "$account_uid" -f '^.*/SquirrelEnhancedDev.app/Contents/(MacOS/|Resources/SquirrelVoiceHelper.app/Contents/MacOS/)' >/dev/null; then
  echo '仍有输入法进程，保留原应用，安装已取消。' >&2; exit 2
fi
mkdir -p '/Library/Input Methods' "$backup_root"
/usr/sbin/chown root:wheel '/Library/Application Support/SquirrelEnhancedDev' "$backup_root"
/bin/chmod 755 '/Library/Application Support/SquirrelEnhancedDev' "$backup_root"
source "$script_directory/app-install-transaction.sh"
run_input_method_registrar() {
  as_console_user /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister "$@"
}
register_input_method_target() {
  # macOS 27 has a root-owned IntlDataCache in addition to each user's TIS
  # registration. User-only registration can leave the system menu/sandboxed
  # readers on old bundle metadata after an otherwise successful update.
  # The transaction has already protected and verified this exact system app.
  # Never run a user-owned retired copy as root or enable/select as root.
  [[ "$1" == "$target" && ! -L "$1" && "$(/usr/bin/stat -f '%u' "$1")" == 0 ]] || return 2
  local unsafe
  unsafe="$(/usr/bin/find "$1" \( ! -user 0 -o \( ! -type l \( -perm -002 -o -perm -020 \) \) \) -print -quit)" || return $?
  [[ -z "$unsafe" ]] || { echo '系统程序包含非 root 所有或可被其他用户写入的文件；拒绝提权执行。' >&2; return 2; }
  /usr/bin/codesign --verify --deep --strict "$1" || return $?
  "$1/Contents/MacOS/SquirrelEnhancedDev" --register-input-source || return $?
  as_console_user "$1/Contents/MacOS/SquirrelEnhancedDev" --register-input-source
}
prepare_input_method_stage() {
  /usr/sbin/chown -R root:wheel "$1"
  /bin/chmod -R go-w "$1"
}
# A moved user copy is a recoverable backup, never a second registered service.
# No user dictionaries, settings or Keychain items are moved or rewritten.
# Retire it BEFORE publishing the system registration. Otherwise IMK can launch
# the old path in the registration gap, taking the engine lock from the new app.
if [[ -d "$user_app" ]]; then
  as_console_user /bin/mkdir -p "$user_support/install-backups"
  retired="$user_support/install-backups/user-to-system-$(date +%Y%m%d-%H%M%S)-$$.app-backup"
  [[ ! -e "$retired" && ! -L "$retired" ]] || exit 2
  as_console_user /bin/mv "$user_app" "$retired"
  unregister_input_method_copy "$retired"
  unregister_input_method_path "$user_app"
fi
install_development_app "$source_app" "$target" "$backup_root"
# The transaction's registration hook has completed both scopes, including on
# an identical-package reinstall and on restoration of an old system bundle.
as_console_user "$target/Contents/MacOS/SquirrelEnhancedDev" --enable-input-source org.rime.inputmethod.SquirrelEnhanced.Development.Hans
as_console_user /usr/bin/open -g "$target"
echo '已安装到系统输入法目录，用户词库、设置和钥匙串保留。'
