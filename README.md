# Squirrel Voice Input · 鼠须管语音增强输入法
macos系统下当前唯一一款支持字母选词的中文输入法
基于 [Rime / Squirrel](https://github.com/rime/squirrel) 的 macOS 输入法扩展，让拼音输入、空格进入字母选词，以及按住热键说话在同一套输入法中协作。

这是社区衍生项目，并非 Rime、阿里云或火山引擎的官方产品。当前源码版本为 **0.1.20**，主程序运行要求 **macOS 13+**；已构建与使用验证的主要环境为 Apple Silicon。仓库仅发布源码、开发文档、测试及必要的公开默认资源，**没有安装包、个人词库或预置服务凭据**。

## 功能

- **两阶段字母选词**：输入拼音时隐藏候选，第一次空格显示候选，再用字母选择当前页候选。默认 `asdfghjkl`，保留原生翻页、数字选择与词频学习。
- **按住说话**：可录制长按热键、选择麦克风；松开后完成识别，自动输入到原位置并隐藏浮窗。
- **语音服务**：支持千问 Streaming、`qwen-audio-3.1-asr-flash-message` 和豆包流式识别。Message 与豆包提供独立的原生润色开关。
- **统一设置与真实测试框**：保存配置、无音频连接鉴权、权限申请和原生语音输入测试入口。
- **轻量浮窗**：透明度可调，默认显示在屏幕下方、程序坞上方，也可跟随当前输入位置。
- **跨应用定位保护**：校验前台输入会话、光标和窗口；兼容部分微信网页及 Finder 改名框缺少辅助功能属性的情况。目标改变时保留草稿，避免写入其他位置。
- **独立安装与数据目录**：增强版使用自己的应用、设置和 Rime 数据目录，并保留更新回滚入口。

增强选词和语音功能首次默认关闭。需要用户自行选择方案、启用功能并配置热键和服务；默认值不会覆盖已保存配置。

## 开始使用与开发

目前通过源码自行构建，见 [构建说明](docs/BUILDING.md)。原生输入法需要 macOS；Windows / Linux 只能运行兼容的 Lua 和部分 Core 测试，不能运行 macOS 输入法界面。

```bash
git clone https://github.com/weipao163-ctrl/squirrel-voice-input.git
cd squirrel-voice-input
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python tests/test_letter_selection.py
```

若只需要 Rime 两阶段字母选词，可使用 `lua/letter_selection.lua` 和 `config/letter_selection.patch.yaml`；先在隔离配置副本中验证自己的方案，不直接覆盖现有词库。

原生开发的准备、签名、构建、测试与安装步骤分别见：

- [构建与测试](docs/BUILDING.md)
- [使用说明](docs/USAGE.md)
- [架构与目标输入保护](docs/ARCHITECTURE.md)
- [隐私与服务配置](docs/PRIVACY.md)
- [验证范围](docs/VALIDATION.md)
- [开源组件与许可证](THIRD_PARTY_NOTICES.md)

## 隐私

API Key / Access Token 通过系统钥匙串管理，不写入仓库。设置保存服务选择和凭据引用，个人 Rime 词库、学习记录及恢复草稿留在本机。

**云识别会将音频发送到用户选择并配置的百炼或火山引擎服务，可能产生费用；这不是离线识别。** 麦克风仅在明确按住说话或主动测试时启用。连接鉴权不需要音频，但会向配置的服务发起鉴权请求。

仓库没有开发者的 Key、工作空间配置、设备信息、签名私钥、用户设置、个人词库、录音或本机日志。保留的默认方案源码来自公开上游，附来源与许可证；它们不是个人学习词库。

## 项目状态

本机已验证构建、组件回归与安装，微信网页和 Finder 改名场景已有用户成功反馈。组件测试不能代替所有应用、所有设备及第二台 Mac 的实机验收。完整功能验收仍有待覆盖的场景，见 [验证范围](docs/VALIDATION.md)。

自行构建产生的本地签名仅供开发使用，不能等同于 Apple Developer ID 签名和公证。不要把开发包直接当作已经完成 Apple 分发认证的产品。

## 贡献与许可证

欢迎通过 Issues 报告可复现的问题，或提交 Pull Request。请勿上传 API Key、个人词库、录音或未经脱敏的日志；贡献指南见 [CONTRIBUTING.md](CONTRIBUTING.md)。

Squirrel 衍生主程序遵循上游 **GPL-3.0**，完整文本见 [LICENSE](LICENSE)。独立增强模块及 Lua 等原有 MIT 部分保留各自许可证，公开默认资源和第三方组件保留其原许可证；具体范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
