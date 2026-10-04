#!/usr/bin/env bash
# Downloads public dependencies into this checkout only; no personal Rime data.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo '原生依赖准备需要 macOS。' >&2; exit 2; }
cd "$root/enhanced-squirrel"
export SQUIRREL_BUNDLED_RECIPES="${SQUIRREL_BUNDLED_RECIPES:-:preset}"
mkdir -p download
while IFS=' ' read -r filename url expected; do
  archive="download/$filename"
  if [[ ! -f "$archive" ]]; then
    curl --fail --location --proto '=https' --tlsv1.2 --retry 2 --output "$archive" "$url"
  fi
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "公开依赖校验失败：$filename" >&2; exit 2; }
done < <(python3 - "$root/DEPENDENCIES.lock.json" <<'PYLOCK'
import json,sys
for item in json.load(open(sys.argv[1]))['archives']:
    print(item['file'],item['url'],item['sha256'])
PYLOCK
)
no_download=1 bash action-install.sh
mkdir -p "$root/evidence" "$root/enhanced-squirrel/build"
echo '公开依赖已准备；未安装、未切换输入法，未读取个人词库。'
