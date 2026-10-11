# 0.1.24：修复按住说话时的误打断

0.1.24 修复了一条会将正常输入框通知误判为目标失效的代码路径。本机已更新，设置与词库保持原样。此版本仍采用本地证书签名，首次安装需在系统「隐私与安全」中手动允许；源码与安装包见 [v0.1.24 发布页](https://github.com/weipao163-ctrl/squirrel-voice-input/releases/tag/v0.1.24)。

## 问题和修复

用户报告约 10% 的录音会在按键仍按住时结束，并显示「已保留草稿／完整结果」。该界面对应识别成功后的目标保护分支，不能据此归因于麦克风选择或鉴权失败。

原监听器收到 AX 输入值、选区或焦点通知就无条件撤销目标；还会把任何应用的激活／失活通知视为目标变化。通知重复、控件重绘或后台激活，即使原生选区、客户端和窗口没有改变，也能触发 `targetInvalidated`、停止采音，最终进入草稿分支。另一个相关问题是，已捕获的 AX 元数据短暂查询失败时，周期检查会立即撤销原目标。

新版将这些通知合并为异步复核，沿用普通拼音的原生 IMK 客户端、选区、光标及窗口绑定。仅通知到达不再等于焦点丢失。AX／位置短暂不可读取时最多重试 0.8 秒，持续失败仍停止；明确更换字段、选区、窗口、输入源或安全状态，以及点击和普通按键，仍立即撤销。滚动只有确认原位置变化才撤销。应用激活通知核验实际前台归属，睡眠／会话／空间变化仍立即停止。

完整识别结果上屏前必须通过一次新的位置核验。短暂失败会自动重试，不能使用旧的成功结果绕过保护；过期或撤销的会话不自动插入。生产心跳加入公共 RunLoop 模式，避免事件跟踪期间停止续约。自己的提交仍复用原生 `commit(string:)`，提交前撤销观察，未知提交结果不重试。

## Evidence → Finding → Path

| Evidence | 本次观察 | 复现或核验入口 |
| --- | --- | --- |
| E-001 | 0.1.23 观察回调无条件执行 `revoke()`；源文件 SHA-256 `018212698607df161ad46df48d399cda94022c8cc52ea725a00dc3753315560e` | 对照 v0.1.23 的 `EnhancementTarget.startNativeMonitoring()` |
| E-002 | 105 项生产快照和监听器夹具通过；包含连续 500 次无位置变化通知、超时恢复、持久超时、真实光标移动、重复回调和重入撤销 | `python3 tools/run_native_voice_target.py` |
| E-003 | 159 项 Core 原断言测试体通过，采用 Apple Swift Testing 适配 | `python3 tools/run_macos_core.py` |
| E-004 | 12 项真实签名 IPC 场景、11 项配置与 11 项启动检查通过；测试与 App 使用同一记录的 SDK | `python3 tools/run_native_ipc_trust.py` |
| E-005 | 从实际包重新解出载荷核对签名和文件；14 项真实 Rime 字母夹具及 6 套空白数据默认方案通过 | `python3 tools/record_macos_build.py`，然后 `python3 tools/build_macos_installer.py` |
| E-006 | 从同一包的载荷完成本机用户更新；243 个安装文件一致；受保护设置／词库源文件哈希不变，焦点权限保留 | 本机私有安装报告，不随源码上传 |

**Finding F-001（validated，依据 E-001／E-002）**：通知被当作失效事实，会产生与截图一致的误停录音和保留草稿路径。修复后无变化通知不撤销，明确变化与持续不可核验仍阻止自动输入。旧截图发生时的具体通知记录没有保存，因此没有将那一次事件归因到某一条已观察到的系统通知。

**Path P-001（callflow，E-001 → F-001 → E-002）**：AX／应用通知 → 原来无条件 `revoke()` → 控制器发送 `targetInvalidated` → 停止采音 → 完整识别转草稿。新版改为 `scheduleInspection()` → 复核原生目标 → 未变化继续录音；确认变化才走停止路径。

## 如何复验

在仓库根目录、已有开发依赖的 macOS 环境执行：

```bash
python3 tools/run_native_voice_target.py
python3 tools/run_macos_core.py
ENHANCEMENT_LOCAL_SIGNING=1 bash enhanced-squirrel/scripts/build-clt.sh
python3 tools/run_native_ipc_trust.py
python3 tools/record_macos_build.py
python3 tools/build_macos_installer.py
```

这些受控检查不录制真人音频、不读取文档正文，也不上传语音。实际使用复验需在之前容易出现问题的输入框中连续按住热键说话并松开，确认录音不会无故提前结束、最终结果自动上屏且浮窗隐藏；使用云服务会按用户账号规则计费。

本次完成了源码路径修复、受控回归、真实构建与本机安装检查；没有采集真人音频重现原来的约 10% 发生率，没有把夹具通过等同于所有应用或第二台 Mac 的实机验收。本机诊断文件保存在被忽略的 `evidence/`，不随公开源码发布。

## 交付

安装包：`SquirrelVoiceInput-0.1.20261011.1-arm64.pkg`，App／Helper 0.1.24，12,800,907 字节。

SHA-256：`90e945e2877ce42451bb0031bd4b1974c81f7d6f0a15f3a95cdb503d23cc3990`。

使用公开默认方案和默认外观；不包含个人词库、设置、API Key、Token、录音、签名私钥或本机日志。安装后保留现有用户配置与本地词库。
