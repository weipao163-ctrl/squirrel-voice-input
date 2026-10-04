# 贡献指南

Issues 和 Pull Requests 都欢迎。请先阅读 README、构建说明和隐私说明。

## 报告问题

提供 macOS 版本、芯片类型、输入法源码版本、应用名称、复现步骤、期望与实际行为。涉及热键时说明是按住还是点击；涉及目标输入框时说明普通拼音能否输入、目标是否会在识别结束前改变。

不要提交 API Key、Access Token、个人词库、文件名、聊天正文、账号资料或原始录音。诊断输出可能含本机路径和服务信息，提交前请逐项脱敏。无法公开的安全问题按 SECURITY.md 处理。

## 修改与测试

尽量让每个 Pull Request 解决一个明确问题。保持现有 IMK 输入、Rime 提交和用户数据边界；勿通过全局按键粘贴或放宽所有焦点校验规避特定应用问题。

修改 Core 时运行 Swift 测试；修改 Lua 时运行 Lua 回归；修改原生目标定位、音频转换或安装逻辑时运行对应离线夹具。构建和人工实机验收分别记录，不用模拟测试代替麦克风或云识别成功。

```bash
python3 tools/check_public_source.py
python3 tests/test_public_source.py
.venv/bin/python tests/test_letter_selection.py
.venv/bin/python tests/test_app_install_transaction.py --bash /bin/bash
swift test --package-path enhanced-squirrel/Enhancements
```

发布前只提交经过检查的源码和公开资源，不提交 `build/`、`evidence/`、`dist/`、本机配置或私钥。新增依赖须说明来源、固定版本和许可证。贡献保留对应目录的现有许可；不移除原作者署名。
