#!/usr/bin/env bash
# Fixed public build dependency, workspace-only. Never installs an application.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if [[ -d Frameworks/Sparkle.framework ]]; then
  echo '已有 Sparkle.framework，未覆盖；版本和来源应按构建报告核对。'; exit 0
fi
mkdir -p download Frameworks
archive="download/Sparkle-2.6.2.tar.xz"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 \
    'https://github.com/sparkle-project/Sparkle/releases/download/2.6.2/Sparkle-2.6.2.tar.xz' -o "$archive"
fi
expected='2300a7dc2545a4968e54621b7f351d388ddf1a5cb49e79f6c99e9a09d826f5e8'
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo 'Sparkle 压缩包哈希不匹配，未解压/未安装。' >&2; exit 1; }
stage="$(mktemp -d "$root/download/sparkle-stage.XXXXXX")"
tar -xJf "$archive" -C "$stage"
cp -R "$stage/Sparkle.framework" Frameworks/
echo 'Sparkle 2.6.2 已核验并复制到工作区 Frameworks；没有运行下载的程序。'
