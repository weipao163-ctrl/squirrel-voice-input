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

Git 代码区只含源码与资源；下载的运行库是本地构建依赖。可安装的编译产物单独放在 Releases，不进入源码历史。已有官方 Squirrel 也可通过 `SQUIRREL_RUNTIME_APP` 显式提供只读运行依赖，默认构建不要求安装官方输入法。

## 本地构建

```bash
ENHANCEMENT_LOCAL_SIGNING=1 bash enhanced-squirrel/scripts/build-clt.sh
```

默认从 `xcrun` 发现 SDK，并用当前编译器实际检查 SwiftUI `@State`。若最新 CLT SDK 缺少对应宏插件，会尝试其他已安装 SDK；不改变系统的 Xcode 选择。必要时用 `ENHANCEMENT_SDK_PATH` 指定兼容 SDK，或安装匹配的 Xcode / CLT。构建输出在 `enhanced-squirrel/build/CLT/SquirrelEnhancedDev.app`。

此路径在副本的 `build/local-signing/` 生成独立证书和私钥，主程序与 Helper 使用同一证书绑定 IPC。不导入钥匙串，不改变系统信任；不要提交或分享该私钥。保留自己的签名身份有助于后续更新继续匹配已有权限。

如果不设置 `ENHANCEMENT_LOCAL_SIGNING=1`，构建只生成 ad-hoc 开发候选，生产语音 IPC 不启用。完整 Xcode 与真实 Developer ID 的另一构建路径见 `enhanced-squirrel/scripts/build-enhanced.sh`；开发者须提供自己的身份，仓库不附签名凭据。

签名前使用系统 `strip -S` 去除主程序和 Helper 的调试对象路径，保留运行时符号。

本地签名不能替代 Apple Developer ID 签名或公证；首次安装需按 [安装说明](INSTALLATION.md) 在系统隐私与安全中允许。原生主程序针对 macOS；源码里的 Windows 夹具不是 Windows 输入法 GUI。

## 测试

```bash
# 公开文件边界与常见凭据检查
python3 tools/check_public_source.py
python3 tests/test_public_source.py
python3 tests/test_app_update_preparation.py
# Lua 和安装事务：不操作正在使用的输入法
.venv/bin/python tests/test_letter_selection.py
.venv/bin/python tests/test_app_install_transaction.py --bash /bin/bash
# 完整 Xcode 的 Core XCTest
swift test --package-path enhanced-squirrel/Enhancements
# 已安装增强版时，数字回归只使用新建隔离数据，不修改现用词库
python3 tools/run_digit_input_regression.py
# 先构建：生产控制器、真实 Rime 与隔离客户端的首键和响应检查
python3 tools/run_native_keyboard_input.py
# 只有 CLT 时，使用 Swift Testing 运行同一组 Core 测试体
python3 tools/run_macos_core.py
# 离线原生目标快照夹具：不采音、不联网
python3 tools/run_native_voice_target.py
# 完成本地证书构建后，IPC 测试复用构建记录中的 SDK
python3 tools/run_native_ipc_trust.py
```

其他原生音频、候选、IPC、编辑器和 Rime 测试入口在 `tools/`。部分入口需要先完成本地构建或前台夹具窗口。输出写入被忽略的 `evidence/` 和 `build/`，不要直接上传本机报告。

## 生成安装包

完成本地签名构建和上面的原生目标／IPC 回归后，再记录构建来源并生成包：

```bash
python3 tools/record_macos_build.py
python3 tools/build_macos_installer.py
```

打包入口要求来源绑定的构建与 IPC 报告，重新解开实际候选包核对文件、签名，并在空白用户数据中运行字母与全部默认方案检查。公开包还需检查个人词库、设置、凭据、私钥、录音和本机路径；本机完整报告不能直接作为公开发布附件。

0.1.28 的公开增强拼音源词表已固定在 `enhanced-squirrel/resources/PublicPinyin`，来源与每文件哈希见 `UPSTREAM.json`。两条构建路径均在签名前验证并打包声明文件，在新建隔离数据目录预编译该词表的 table/prism/reverse 三个文件。生成物的来源哈希及文件哈希保存在包内 `Resources/Licenses/PublicPinyin-PREBUILT.json`，不读取或复制开发机器的个人词库。可运行 `tools/run_public_pinyin_probe.py --shared <App的SharedSupport绝对路径> --library <App的librime绝对路径>` 复验；测试仅创建隔离目录。

## 自行安装

```bash
bash enhanced-squirrel/scripts/install-dev.sh --dry-run
# 阅读检查结果并保存工作后执行
bash enhanced-squirrel/scripts/install-dev.sh --apply
```

安装目录为当前用户的 `~/Library/Input Methods/SquirrelEnhancedDev.app`，设置与词库位于 `~/Library/Application Support/SquirrelEnhancedDev`。增强版使用独立标识，更新保留设置，并记录回滚备份。首次安装后可能需要注销并重新登录，再从系统设置添加“鼠须管增强开发版”。

不要使用上游 Makefile 的系统安装目标替代增强版安装脚本。预编译安装包从 [Releases](https://github.com/weipao163-ctrl/squirrel-voice-input/releases) 下载；`tools/build_macos_installer.py` 只会在本地构建和来源绑定的回归报告齐全后生成候选包，不能绕过签名与验证要求。

键盘持续输入、资源指标和旧控制器对照的测量范围见[0.1.27 性能报告](2026-10-14_keyboard-performance-report.md)。`tools/run_native_keyboard_input.py --label custom-run` 保存独立报告；原生候选窗口检查自动复用 CLT 构建的 SDK。

首次输入候选位置的重试、取消、模式提示及竖排布局回归见[0.1.28 定位报告](2026-10-14_fix-candidate-position-report.md)。多 SDK 环境运行 `run_native_audio.py` 时，用 `--sdk` 显式指定构建记录中的 SDK；该工具会重建 `swift-clt` 模块，不要与其他使用该目录的构建/检查并行运行。

## 0.1.31 首次字母选词默认值

两条构建路径在公开词库预编译前执行 `tools/bundle_default_letters.py`，仅向 App 的 SharedSupport 和 Resources 写入已声明的默认朙月拼音补丁及生产 Lua。用户目录不参与构建。`SettingsStore` 只有在设置文件缺失时使用新默认，已有保存值和禁用选择按原值解析。手动修改方案结构仍保留部署入口。

```bash
python3 tools/run_default_letters.py --app enhanced-squirrel/build/CLT/SquirrelEnhancedDev.app
```

此检查在新的隔离目录启动实际包内 Rime；分别覆盖首次空格/字母/禁用和用户自定义补丁优先级。详情见[修复与验收范围](2026-10-14_fix-default-letter-selection-report.md)。

## 0.1.32 候选窗可见性

```bash
python3 tools/run_native_keyboard_input.py --label candidate-visibility
python3 tools/run_native_candidate_panel.py
python3 tools/run_native_voice_target.py
```

键盘夹具模拟坐标暂缺、持续缺失和分页过程中间歇缺失，检查候选回退、恢复及请求撤销；AppKit 夹具检查横/竖排的实际屏幕边界。它们不连接微信真实输入框，也不采音或调用云端服务。旧控制器的 7 项失败对照与验收边界见[报告](2026-10-15_fix-candidate-visibility-report.md)。


### 0.1.33 坐标恢复与性能回归

```bash
python3 tools/run_native_keyboard_input.py --label caret-reliability
python3 tools/run_native_candidate_panel.py
python3 tools/run_native_voice_target.py
```

79 项键盘检查执行实际生产控制器、实际候选面板与隔离的真实 Rime：覆盖连续内容更新、慢速 AX、单任务合并、缓存失效、迟到结果、原生结果优先和宿主代理更换。AX 传输与测试时钟可注入；隔离宿主不监听用户正在其他应用进行的操作，真实系统监听需要另做应用层验证。原生目标另有 106 项检查。

`--controller-source` 允许在同一构建环境载入旧控制器，旧版只执行原有 56 项通用检查。性能段固定测试 `nihao` 后 Esc，包含 24,000 次 down/up 事件、100 个新控制器、500 次激活和进程资源采样；这是夹具内耗时，不是物理键盘或目标软件端到端延迟。见[本版报告](2026-10-15_fix-caret-reliability-report.md)。

已安装应用可运行 `--candidate-position-stats` 读取最多 64 个样本的内存统计；`--candidate-position-check` 显式查询当前前台客户端的原生/AX 坐标可用性。命令不录音、不调用云服务、不读取正文、不插入字符、不显示或移动候选窗；检查前应在普通文本框中选中增强版输入法。

## 0.1.36 助手内存回归

构建 Helper 模块后运行 `python3 tools/run_helper_memory_probe.py --mode closed --label memory-closed`。另以 `hidden` 和 `miniaturized` 检查隐藏和最小化。该检查使用原生设置界面、6,000 次合成状态更新和 20 次开关，记录物理内存足迹；不使用麦克风、Keychain 或语音网络服务。见[内存修复报告](2026-10-26_fix-helper-memory-report.md)。
