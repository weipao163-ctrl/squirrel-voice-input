# 0.1.32：候选窗间歇不可见修复

修复偶发“文字可以上屏，但按空格也看不到任何候选界面”的显示路径。用户报告在微信出现，且并非每次发生。修复作用于所有普通键盘输入框共用的流程，不增加应用或控件名单。

## 根因与修改

E-1 → F-1 → P-1：旧控制器将候选窗是否可见绑定到 `KeyboardInputPosition.caret` 是否成功。宿主暂时没有布局坐标时，每次查询失败都会隐藏窗口；约 1 秒的 8 次查询结束后仍隐藏。新按键又会撤销并重新发起定位，所以即使组合和提交正常，间歇缺失坐标也会让候选消失，持续缺失时更无法恢复显示。这是可复现的共用代码缺陷；尚未在微信中捕获用户当时那一次失败的现场，不能声称已证明微信每次偶发都来自同一原因。

P-1：Rime 更新候选 → 按键回调结束后读取当前客户端光标 → 有有效坐标则贴近光标；没有坐标则在可用屏幕下方中央、程序坞上方呈现当前候选。显示回退立即生效，不依赖耗尽重试，因此快速连续按键不会让它一直等待。原有有限重试继续运行，取得坐标后恢复到光标旁；约 1 秒后停止空闲查询，下一次输入仍可继续恢复。

E-2 → F-1 → P-1：同一 56 项生产控制器/真实 Rime 夹具在旧控制器下有 7 项失败，修复后全部通过。包含首次没有坐标、始终缺少坐标、分页途中临时丢失、快速更新、换输入框、原生选词、恢复与隐藏。并非靠伪造成功的光标坐标解决：`KeyboardInputPosition` 与语音目标验证均未更改，回退只影响候选窗绘制位置。

E-3 → F-2 → P-2：候选窗旧配置没有声明跨 Space 与全屏辅助窗口行为。本次明确设置 `canJoinAllSpaces`、`fullScreenAuxiliary`，继续使用不激活的原生面板和显式提交/失焦隐藏。此项是显示策略补齐，属性与横/竖排渲染夹具通过，不等同于已实测全部全屏应用。

P-2：当前控制器拥有显示请求 → 请求号、输入代次、客户端及活动控制器在查询前后均校验 → 提交、Esc、切换客户端或失焦撤销重试并隐藏 → 迟到的旧控制器不能隐藏新窗口。回退不复用旧输入框锚点，不改变 `insertText` 的目标或选词逻辑。空格前按设置隐藏候选时仍为零次宿主几何查询；只有模式提示、没有组合的请求继续等待有效坐标，不让过期模式提示成为永久窗口。

## 检查与证据

本轮未采集真人音频、读取 Keychain 值或调用云识别；全部输入夹具使用公开小词库及新建隔离目录。原始报告含机器路径，留在被忽略的 `evidence/`，不随公开源码发布。

| Evidence | 实际观察 | 本机报告 SHA-256 |
| --- | --- | --- |
| E-1 | 相同 56 项键盘夹具的旧控制器有 7 项候选可见性失败 | `379ede06d4775d96d86345c91b1c1bbbfdd1140ca79b52217e97776dca64d327` |
| E-2 | 修复后的 56 项通过，包含 24,000 次按键事件、100 个新控制器和 500 次激活；隐藏候选为零次几何查询 | `345e991f8e038db3a2aa19ad58e8f263842007ec4305c7359631cb374875ac6a` |
| E-3 | 18 项实际 AppKit 候选检查通过，含横/竖排回退、屏幕内边界、恢复及 Space 配置 | `e19454117eaaf731ec907021dc86cbe4fe658dbb194ab17faffc88bfa7567881` |
| E-4 | 105 项原生语音目标检查通过；不使用候选回退坐标授权上屏 | `02e69460da742a1adba545e12cfbe6341c7e34370050c21bb22ff80293ee1022` |
| E-5 | 164 项真实 Swift Testing 通过；执行原 XCTest 断言体，不能称为原生 XCTest 验收 | `4c60dba961136aaaec188b06b6e629afc76095623f1dec9c1a7c230b2cd499d0` |

另有 12 项新用户默认字母/自定义补丁覆盖、12 项真实签名 IPC、各 11 项配置与启动边界检查通过。完整安装包重新解开，核对实际 App、签名和安装脚本；14 项字母用例与全部 6 个默认方案的空白数据检查通过。与前一公开包比较，269 个文件/链接的集合保持一致，261 个内容不变，只有 8 个声明的二进制、版本、签名和公开预编译元数据变化；无新增私有资源。

可复验命令（先按 BUILDING.md 完成构建）：

```bash
python3 tools/run_native_keyboard_input.py --label candidate-visibility
python3 tools/run_native_candidate_panel.py
python3 tools/run_native_voice_target.py
python3 tools/run_default_letters.py --app enhanced-squirrel/build/CLT/SquirrelEnhancedDev.app
python3 tools/run_native_ipc_trust.py
python3 tools/record_macos_build.py
python3 tools/build_macos_installer.py
```

旧控制器对照可在当前源码及构建环境中运行，预期返回失败并记录 7 项失败：

```bash
baseline_dir="$(mktemp -d)"
git show v0.1.31:enhanced-squirrel/sources/SquirrelInputController.swift > "$baseline_dir/SquirrelInputController.swift"
python3 tools/run_native_keyboard_input.py --controller-source "$baseline_dir/SquirrelInputController.swift" --label visibility-before
```

## 安装、数据与边界

App/Helper 为 0.1.32，Apple Silicon 完整安装包为 `SquirrelVoiceInput-0.1.20261015.32-arm64.pkg`，SHA-256 为 `0820ee1872806035aa4e424b09e907b59d85151d5895caf2ca4ea49d045a9a69`。本机通过共享安装事务更新到 0.1.32，原有 SharedSupport 的 63 个文件保持原字节，249 个设置/词库文件在替换前后哈希不变；这是本机程序事务验收，未重新操作系统 Installer 图形界面。

公开源码与安装包继续提供固定公开雾凇词表、默认字母选词及外观；本机使用的词库不被替换。发布包没有本机个人词库、学习记录、设置、API Key、签名私钥或调试日志。首次安装仍需按[安装说明](INSTALLATION.md)在系统「隐私与安全」允许：当前使用本地签名，未经过 Apple Developer ID 签名与公证。

组件回归和本机更新不能代替微信真实输入的长期观察，也不能代替第二台 Mac 真机安装；本轮未宣称上述场景已经全部完成。若宿主不提供光标坐标，候选会暂留屏幕下方中央，文字仍通过当前 IMK 会话输入原位置。
