#!/usr/bin/env bash
# Sourced by install-dev.sh AFTER platform, signature, bundle ID and process checks.
# File transaction only. Never enables/selects/restarts an input method.
install_development_app() (
  set -euo pipefail
  source_app="$1"; target="$2"; backup_root="$3"
  for path in "$source_app" "$target" "$backup_root"; do
    [[ "$path" == /* && "$path" != *$'\n'* && ! -L "$path" ]] || {
      echo '安装路径必须是绝对路径，不能是符号链接或包含换行。' >&2; exit 2;
    }
  done
  [[ -d "$source_app" && "$source_app" != "$target" && "${target##*/}" == SquirrelEnhancedDev.app ]] || exit 2
  mkdir -p "$(dirname "$target")" "$backup_root"
  lock="$target.install-lock"
  mkdir "$lock" 2>/dev/null || {
    echo "安装事务锁已存在；保留现场，不自动抢锁：$lock" >&2; exit 2;
  }
  stage=''; backup=''; moved_old=0; installed_new=0
  operation="$(date +%Y%m%d-%H%M%S)-$$"
  failed="$backup_root/failed-$operation.app"
  aborted="$backup_root/staged-$operation.app"
  # Never overwrite an earlier recovery bundle, even on timestamp/PID reuse.
  [[ ! -e "$failed" && ! -L "$failed" && ! -e "$aborted" && ! -L "$aborted" ]] || {
    rmdir "$lock"; echo '备份名称冲突，保留现场。' >&2; exit 2;
  }
  cleanup_install() {
    status=$?
    trap - EXIT INT TERM
    if [[ "$status" != 0 ]]; then
      if [[ "$installed_new" == 1 && -d "$target" ]]; then
        if diff -qr "$source_app" "$target" >/dev/null 2>&1; then
          mv "$target" "$failed" || echo '新包保留在目标位置；移动失败，请人工恢复。' >&2
        else
          echo '目标在事务中发生后续修改，保留目标；不覆盖它。' >&2
        fi
      fi
      if [[ "$moved_old" == 1 && -d "$backup" && ! -e "$target" && ! -L "$target" ]]; then
        mv "$backup" "$target" || echo "旧包恢复失败；可恢复备份：$backup" >&2
      fi
      echo "安装失败（退出码 ${status}）；恢复资料目录：$backup_root" >&2
    fi
    if [[ -n "$stage" && -d "$stage" ]]; then
      mv "$stage" "$aborted" || echo "未完成 staging 保留在：$stage" >&2
    fi
    # Only our one metadata file/empty lock are removed, never recursive deletion.
    rm -f "$lock/transaction.txt"
    rmdir "$lock" || echo "事务锁未清理：$lock" >&2
    exit "$status"
  }
  trap cleanup_install EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ -d "$target" ]] && diff -qr "$source_app" "$target" >/dev/null 2>&1; then
    codesign --verify --deep --strict "$target"
    echo '相同开发包已安装；未复制、未增加备份、未重复注册。'
    exit 0
  fi
  stage="$target.new.$$"
  [[ ! -e "$stage" && ! -L "$stage" ]] || { stage=''; echo 'staging 名称冲突，不覆盖。' >&2; exit 2; }
  backup="$backup_root/app-$operation.app"
  [[ ! -e "$backup" && ! -L "$backup" ]] || { stage=''; echo '旧包备份名称冲突，不覆盖。' >&2; exit 2; }
  printf 'source=%s\ntarget=%s\nstage=%s\nbackup=%s\nphase=prepared\n' \
    "$source_app" "$target" "$stage" "$backup" > "$lock/transaction.txt"
  ditto "$source_app" "$stage"
  codesign --verify --deep --strict "$stage"
  if [[ -d "$target" ]]; then
    printf 'phase=moving-old\n' >> "$lock/transaction.txt"
    moved_old=1; mv "$target" "$backup"
  fi
  printf 'phase=installing-new\n' >> "$lock/transaction.txt"
  installed_new=1; mv "$stage" "$target"; stage=''
  printf 'phase=registering\n' >> "$lock/transaction.txt"
  "$target/Contents/MacOS/SquirrelEnhancedDev" --register-input-source
  echo '已安装/注册。请在系统设置手动添加开发输入源；无需替换正式版。'
)
