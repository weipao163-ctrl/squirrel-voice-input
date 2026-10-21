# 0.1.34：修复返回旧窗口后持续不显示候选窗

发布状态：0.1.34 当时仅用于本机验收；其中修复与回归测试于 2026-10-21 随 0.1.35 一并发布，未单独发布 0.1.34 安装包。

本版针对“在长时间未激活的窗口里，文字可以上屏，拼音和空格候选却持续不可见；切到其他窗口输入再回来才恢复”的问题。修复适用于共享输入控制流程，不依赖微信、WPS 或特定控件名单。

用户报告的现场在诊断前已经自行恢复。因此，下文区分生产代码隔离复现与真实应用验收，不将推断写成已捕获的现场调用顺序。

## 复现、根因与修改

**E-1 → F-1 → P-1：显示归属依赖激活通知的顺序。** 旧版只有 `activateServer` 更新活动控制器；而 `handle` 即使实际收到按键并完成 Rime 输入，也不会恢复显示归属。辅助输入会话的激活通知占据活动指针后，原窗口的每次 `showPanel` 都会提前返回。隔离测试让旧窗口完成一次输入，另一个窗口完成十次输入，再将真实按键交给原控制器、不给它额外激活通知：旧版连续二十次组合均未恢复候选，但文字仍提交到原客户端。这与用户补充的持续性表现一致。

现在以实际收到的 keyDown 或仍按下的修饰键确认归属，撤销旧显示任务并恢复当前控制器；不等待下一次切换窗口。迟到的 keyUp 不得抢走当前显示。这个判断只做本地对象比较，普通按键不新增宿主或辅助功能调用。原有拼音、选词逻辑及文字提交客户端保持不变。

**E-1 → F-2 → P-2：过期任务占住显示调度位置。** 会话代次变化后，旧异步任务在清理自身之前提前返回，后续更新会一直认为“已有显示任务”。现在线程回调先释放属于自己的调度位置，再校验会话；会话创建与部署也主动撤销旧任务。新请求不会被旧回调清除，失焦和提交仍会取消展示。

**E-1 → F-3 → P-3：延后绘制弱引用了回调期间的客户端。** 客户端对象可能在按键回调返回后失效，导致绘制任务在查询坐标之前退出。现在只在有界显示/重试任务期间保留客户端，任务结束释放。回归同时验证候选能出现、完成后客户端能释放，不把临时对象永久留在控制器中。

三个路径均通过 `SquirrelInputController.handle → showPanel → updatePanelPosition → SquirrelPanel.update`；文字仍经原客户端 `insertText` 上屏。显示回退不提供语音目标授权，不放宽安全输入或语音投递验证。

## 验证证据

| Evidence | 本机报告（不随源码发布） | 结果 | SHA-256 |
| --- | --- | --- | --- |
| E-1 | `candidate-invisible-baseline-34.json` | FAIL | `cc7c8a0a3538341bb3b7b2959014182aaa36479c6df12ea4cd5d0075ecee1cc1` |
| E-2 | `candidate-invisible-final-34.json` | PASS | `33a1fa0f7b5029493a451727397da27f5b2deba85ce11faee0e28ff52161d6a8` |
| E-3 | `macos-native-voice-target.json` | PASS | `77a543dd6e731fb1407c9cb4243a6a007e3503b2a1613c2dc7cefeb8bf5f6816` |
| E-4 | `macos-candidate-panel.json` | PASS | `42a88849383e3ad7d7a178ad0fcea4020d7ceea17f9cec5f099242dacbb1cb0b` |
| E-5 | `macos-installer.json` | PASS | `82e39784dc0a61ee2ceabd636f3a3f6980e70a0ff257f7e3ce67770328260b9b` |
| E-6 | `local-install-0.1.34.json` | PASS | `64382818dcd9cf154e0645e2b8f7ddfad44f93befffca6d02c4686aa793ab262` |

相同 93 项检查在旧版出现 8 项失败，在修复版全部通过。包括返回旧窗口连续二十次组合、激活乱序、无额外激活的收键、迟到释放、旧控制器失焦、临时客户端释放、会话代次更新及已有坐标恢复测试。它们编译生产控制器和 AppKit 面板，执行真实 Rime；输入客户端为隔离对象，不冒充微信现场重现。

另有 106 项原生语音目标、18 项 AppKit 候选渲染、12 项签名 IPC 检查通过。实际安装包重新解包核对签名、二进制与脚本；14 项字母行为、6 个默认方案在空白数据目录通过。

复验（先按 BUILDING.md 完成构建）：

```bash
python3 tools/run_native_keyboard_input.py --label candidate-invisible
python3 tools/run_native_voice_target.py
python3 tools/run_native_candidate_panel.py
python3 tools/run_native_ipc_trust.py
python3 tools/record_macos_build.py
python3 tools/build_macos_installer.py
```

对照时将 `v0.1.33:enhanced-squirrel/sources/SquirrelInputController.swift` 保存到独立目录，使用 `--controller-source` 加载。新增断言在旧版必须失败，不能删断言来获得绿色结果。

## 性能与数据边界

实际按键处理只增加本地归属判断；不增加每键几何、AX 或网络调用，不增加常驻轮询。隔离的 12,000 对 down/up 工作量中，修复前后 P95 均约 0.036ms；隐藏候选热路径仍为零次几何查询。此数值不代表物理键盘到微信绘制的端到端延迟；测试前置绘制量不同，不能据夹具整体内存差值声称降低实际应用占用。

诊断新增是否有待绘制任务、面板归属及窗口是否与屏幕相交的布尔值，仍只存固定内存计数，不记录输入文字、按键序列、坐标、使用日志或凭据。

本机更新保留 63 个原 SharedSupport 文件和 223 个设置/词库及其他非运行元数据文件；Rime 重启时的版本元数据、学习数据库日志可正常轮换。没有用公开词库覆盖本机词库，没有读取 Keychain 值。公开包继续使用带来源与哈希的 PublicPinyin，排除个人词库、学习数据库、设置、API Key 和签名私钥。

App/Helper 为 0.1.34，完整包为 `SquirrelVoiceInput-0.1.20261016.34-arm64.pkg`。仍是本机证书签名，未经过 Developer ID 签名/Apple 公证；首次安装须按[安装说明](INSTALLATION.md)在“隐私与安全”中手动允许。

## 本机微信验收

0.1.34 更新后，用户停留在空白聊天框，连续两轮实际按键 `ni → 空格 → a` 均上屏“你”。两轮组合时生产面板均可见、属于当前控制器且位于屏幕内；最终测试文字已清空，未发送消息。原先偶发现场已恢复，不能将本次正常输入称为已重复捕获所有偶发条件；持续二十次不显示的状态通过上述真实控制器隔离回归验证。
