#!/bin/bash
# Installer executes this script only after the human chooses Install.
# Drop privilege before touching the current user's independent input method.
set -euo pipefail
[[ "${3:-}" == / ]] || { echo '只支持当前启动磁盘，不安装到其他卷。' >&2; exit 2; }
[[ "$(id -u)" == 0 ]] || { echo '请通过 macOS 安装器打开此安装包。' >&2; exit 2; }
script_directory="$(cd "$(dirname "$0")" && pwd)"
account="$(/usr/bin/stat -f '%Su' /dev/console)"
[[ "$account" != root && "$account" != loginwindow && "$account" != _mbsetupuser && "$account" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo '需要已登录的本机用户。' >&2; exit 2; }
account_uid="$(/usr/bin/id -u "$account")"
[[ "$account_uid" =~ ^[0-9]+$ && "$account_uid" -ge 500 ]] || exit 2
account_home="$(/usr/bin/dscl . -read "/Users/$account" NFSHomeDirectory | /usr/bin/sed 's/^NFSHomeDirectory: //')"
[[ "$account_home" == /* && -d "$account_home" && ! -L "$account_home" && "$account_home" != *$'\n'* && "$(/usr/bin/stat -f '%u' "$account_home")" == "$account_uid" ]] || { echo '用户主目录不符合安全安装条件。' >&2; exit 2; }
# Installer's private Scripts sandbox may be unreadable after dropping root.
# Copy only this package's verified application/scripts to a root-owned staging
# directory that the user can read, without granting the user write access.
/usr/bin/codesign --verify --deep --strict "$script_directory/SquirrelEnhancedDev.app"
staging="$(/usr/bin/mktemp -d /private/tmp/sqv-install.XXXXXX)"
trap '/bin/rm -rf "$staging"' EXIT
/usr/bin/ditto "$script_directory/SquirrelEnhancedDev.app" "$staging/SquirrelEnhancedDev.app"
/bin/cp "$script_directory/pkg-user-install.sh" "$script_directory/app-install-transaction.sh" "$staging/"
/usr/sbin/chown -R root:wheel "$staging"
/bin/chmod -R a+rX "$staging"
/bin/chmod 755 "$staging"
/bin/launchctl asuser "$account_uid" /usr/bin/sudo -H -u "$account" \
  /bin/bash "$staging/pkg-user-install.sh" "$staging/SquirrelEnhancedDev.app" "$account_home"
