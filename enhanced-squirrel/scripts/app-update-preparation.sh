#!/bin/bash
# Cooperative maintenance only. No signals, forced termination or file writes.
development_app_is_running() {
  /usr/bin/pgrep -u "$(id -u)" -f '^.*/SquirrelEnhancedDev.app/Contents/(MacOS/|Resources/SquirrelVoiceHelper.app/Contents/MacOS/)' >/dev/null
}
prepare_development_app_update() {
  local source_app="$1" target="$2" attempt
  development_app_is_running || return 0
  echo '正在正常退出增强版以安装更新；若设置有未保存修改，请处理保存/取消提示。'
  if ! "$source_app/Contents/MacOS/SquirrelEnhancedDev" --quit --installed-app-path "$target"; then
    echo '更新已取消或退出未完成；原应用、设置与词库均未替换。' >&2
    return 2
  fi
  for attempt in {1..50}; do
    development_app_is_running || return 0
    /bin/sleep 0.1
  done
  echo '增强版仍在运行，保留原安装；请处理未保存提示后重新安装。' >&2
  return 2
}
