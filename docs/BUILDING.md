# 构建与测试

## 环境

- 原生输入法需要 macOS 13+。本地证书构建路径目前限 Apple Silicon。
- 安装 Xcode 或 Apple Command Line Tools；`xcrun --sdk macosx --show-sdk-path` 必须可用。
- Python 3.10+、Git、curl、系统编译和签名工具。
- 第一次准备依赖需要联网。所有下载、证书和产物都留在工作副本，不放入版本库。

## 准备

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
bash scripts/prepare-dependencies.sh
```

准备脚本获取上游 librime 1.17.0、插件、OpenCC 与 Sparkle 2.6.2，默认方案通过公开的 Plum 配方生成。不会读取个人 Rime 目录，不安装或切换输入法。Rime 与 Sparkle 运行档案的 URL 和 SHA-256 固定在 `DEPENDENCIES.lock.json`；本地签名工具也有固定校验值。默认方案配方内容来自其公开仓库，首次联网获取时应审查来源；不宣称全部配方已锁定到相同历史快照。

仓库只含源码与资源；下载的运行库是本地构建依赖，不是本仓库发布的二进制。已有官方 Squirrel 也可通过 `SQUIRREL_RUNTIME_APP` 显式提供只读运行依赖，默认构建不要求安装官方输入法。

## 本地构建

```bash
ENHANCEMENT_LOCAL_SIGNING=1 bash enhanced-squirrel/scripts/build-clt.sh
```

默认从 `xcrun` 发现 SDK，并用当前编译器实际检查 SwiftUI `@State`。若最新 CLT SDK 缺少对应宏插件，会尝试其他已安装 SDK；不改变系统的 Xcode 选择。必要时用 `ENHANCEMENT_SDK_PATH` 指定兼容 SDK，或安装匹配的 Xcode / CLT。构建输出在 `enhanced-squirrel/build/CLT/SquirrelEnhancedDev.app`。

此路径在副本的 `build/local-signing/` 生成独立证书和私钥，主程序与 Helper 使用同一证书绑定 IPC。不导入钥匙串，不改变系统信任；不要提交或分享该私钥。保留自己的签名身份有助于后续更新继续匹配已有权限。

如果不设置 `ENHANCEMENT_LOCAL_SIGNING=1`，构建只生成 ad-hoc 开发候选，生产语音 IPC 不启用。完整 Xcode 与真实 Developer ID 的另一构建路径见 `enhanced-squirrel/scripts/build-enhanced.sh`；开发者须提供自己的身份，仓库不附签名凭据。

本地签名不能替代 Apple Developer ID 签名、公证或正式分发。原生主程序针对 macOS；源码里的 Windows 夹具不是 Windows 输入法 GUI。

## 测试

```bash
# 公开文件边界与常见凭据检查
python3 tools/check_public_source.py
python3 tests/test_public_source.py
# Lua 和安装事务：不操作正在使用的输入法
.venv/bin/python tests/test_letter_selection.py
.venv/bin/python tests/test_app_install_transaction.py --bash /bin/bash
# 完整 Xcode 的 Core XCTest
swift test --package-path enhanced-squirrel/Enhancements
# 只有 CLT 时，使用 Swift Testing 运行同一组 Core 测试体
python3 tools/run_macos_core.py
# 离线原生目标快照夹具：不采音、不联网
python3 tools/run_native_voice_target.py
```

其他原生音频、候选、IPC、编辑器和 Rime 测试入口在 `tools/`。部分入口需要先完成本地构建或前台夹具窗口。输出写入被忽略的 `evidence/` 和 `build/`，不要直接上传本机报告。

## 自行安装

```bash
bash enhanced-squirrel/scripts/install-dev.sh --dry-run
# 阅读检查结果并保存工作后执行
bash enhanced-squirrel/scripts/install-dev.sh --apply
```

安装目录为当前用户的 `~/Library/Input Methods/SquirrelEnhancedDev.app`，设置与词库位于 `~/Library/Application Support/SquirrelEnhancedDev`。增强版使用独立标识，更新保留设置，并记录回滚备份。首次安装后可能需要注销并重新登录，再从系统设置添加“鼠须管增强开发版”。

不要使用上游 Makefile 的系统安装目标替代增强版安装脚本。源码发布不包含现成安装包；`tools/build_macos_installer.py` 只会在本地构建和来源绑定的回归报告齐全后生成候选包，不能绕过签名与验证要求。
