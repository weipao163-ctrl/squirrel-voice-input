#!/usr/bin/env bash
# Sourced by install-dev.sh AFTER platform, signature, bundle ID and process checks.
# File transaction only. Never enables/selects/restarts an input method.
run_input_method_registrar() {
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister "$@"
}

unregister_input_method_path() {
  local path="$1" output status expected
  if output="$(run_input_method_registrar -u "$path" 2>&1)"; then return 0; else status=$?; fi
  # lsregister exits 1 when an exact owned copy was never registered. Treat
  # only the observed kLSApplicationNotFoundErr diagnostic as idempotent.
  # Do not swallow permissions, corrupt bundles, other OSStatus values or
  # additional errors merely because their output contains "-10814".
  expected="failed to scan $path: -10814"
  if [[ "$status" == 1 && ( "$output" == "$expected" || "$output" == "$expected"$'\n from spotlight' ) ]]; then
    return 0
  fi
  printf '%s\n' "$output" >&2
  return "$status"
}

unregister_input_method_copy() {
  # Only exact source/backup paths owned by this transaction. Do not reset the
  # system registry or unregister the installed destination/other input methods.
  local helper="$1/Contents/Resources/SquirrelVoiceHelper.app" helper_status=0 app_status=0
  if [[ -d "$helper" && ! -L "$helper" ]]; then
    unregister_input_method_path "$helper" || helper_status=$?
  fi
  # A Helper error must not leave its parent registered as another live copy.
  unregister_input_method_path "$1" || app_status=$?
  if [[ "$helper_status" != 0 ]]; then return "$helper_status"; fi
  return "$app_status"
}

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
  # Recovery directories avoid the .app suffix; their nested Helper is also
  # unregistered. Restore by moving back to the exact installed .app path.
  failed="$backup_root/failed-$operation.app-backup"
  aborted="$backup_root/staged-$operation.app-backup"
  # Never overwrite an earlier recovery bundle, even on timestamp/PID reuse.
  [[ ! -e "$failed" && ! -L "$failed" && ! -e "$aborted" && ! -L "$aborted" ]] || {
    rmdir "$lock"; echo '备份名称冲突，保留现场。' >&2; exit 2;
  }
  cleanup_install() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "$status" != 0 ]]; then
      if [[ "$installed_new" == 1 && -d "$target" ]]; then
        if diff -qr "$source_app" "$target" >/dev/null 2>&1; then
          if mv "$target" "$failed"; then
            unregister_input_method_copy "$failed" ||
              echo "失败新包已保留，但系统注册清理失败：$failed" >&2
          else
            echo '新包保留在目标位置；移动失败，请人工恢复。' >&2
          fi
        else
          echo '目标在事务中发生后续修改，保留目标；不覆盖它。' >&2
        fi
      fi
    fi
    # Clear only transaction-owned artifacts, before re-registering the restored
    # target. A cleanup error is reported but must not interrupt file rollback.
    if [[ -n "$stage" && -d "$stage" ]]; then
      if mv "$stage" "$aborted"; then
        unregister_input_method_copy "$aborted" ||
          echo "未完成 staging 已保留，但系统注册清理失败：$aborted" >&2
      else
        echo "未完成 staging 保留在：$stage" >&2
        unregister_input_method_copy "$stage" ||
          echo "未完成 staging 的系统注册清理失败：$stage" >&2
      fi
    fi
    if [[ "$status" != 0 ]]; then
      if [[ "$moved_old" == 1 && -d "$backup" && ! -e "$target" && ! -L "$target" ]]; then
        mv "$backup" "$target" || echo "旧包恢复失败；可恢复备份：$backup" >&2
        if [[ -d "$target" ]]; then
          "$target/Contents/MacOS/SquirrelEnhancedDev" --register-input-source ||
            echo '旧包文件已恢复，但系统注册刷新失败；请重新安装或注销后登录。' >&2
        fi
      fi
      echo "安装失败（退出码 ${status}）；恢复资料目录：$backup_root" >&2
    fi
    # Only our one metadata file/empty lock are removed, never recursive deletion.
    rm -f "$lock/transaction.txt" || echo "事务锁元数据未清理：$lock/transaction.txt" >&2
    rmdir "$lock" || echo "事务锁未清理：$lock" >&2
    exit "$status"
  }
  trap cleanup_install EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ -d "$target" ]] && diff -qr "$source_app" "$target" >/dev/null 2>&1; then
    codesign --verify --deep --strict "$target"
    unregister_input_method_copy "$source_app"
    "$target/Contents/MacOS/SquirrelEnhancedDev" --register-input-source
    echo '相同开发包已安装；未复制、未增加备份，已刷新系统注册。'
    exit 0
  fi
  stage="$target.new.$$"
  [[ ! -e "$stage" && ! -L "$stage" ]] || { stage=''; echo 'staging 名称冲突，不覆盖。' >&2; exit 2; }
  backup="$backup_root/app-$operation.app-backup"
  [[ ! -e "$backup" && ! -L "$backup" ]] || { stage=''; echo '旧包备份名称冲突，不覆盖。' >&2; exit 2; }
  printf 'source=%s\ntarget=%s\nstage=%s\nbackup=%s\nphase=prepared\n' \
    "$source_app" "$target" "$stage" "$backup" > "$lock/transaction.txt"
  ditto "$source_app" "$stage"
  codesign --verify --deep --strict "$stage"
  if [[ -d "$target" ]]; then
    printf 'phase=moving-old\n' >> "$lock/transaction.txt"
    moved_old=1; mv "$target" "$backup"
    unregister_input_method_copy "$backup"
  fi
  printf 'phase=installing-new\n' >> "$lock/transaction.txt"
  installed_new=1; mv "$stage" "$target"; stage=''
  printf 'phase=registering\n' >> "$lock/transaction.txt"
  unregister_input_method_copy "$source_app"
  "$target/Contents/MacOS/SquirrelEnhancedDev" --register-input-source
  echo '已安装/注册。请在系统设置手动添加开发输入源；无需替换正式版。'
)
