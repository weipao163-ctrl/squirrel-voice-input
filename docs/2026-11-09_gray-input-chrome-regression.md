# 2026-11-09：Chrome 密码框退出后输入法变灰

本次已定位到 Chrome 156 的焦点回归，并在用户同意正常重启 Chrome 后启用兼容参数。用户最终确认：连续两次从测试密码框直接返回微信，中文正常，语音也正常。未整机重启验收，不承诺其他独立触发条件永不发生。0.1.43 已在本机安装，尚未发布 GitHub。

## 根因与现场对照

初始主程序、Helper 均为 0.1.42，进程存活、签名正常；输入源已启用且持久名单完整，正式安装路径也是首选。主线程采样在正常事件循环，没有发现对应崩溃。这排除了“重新添加名单即可完成修复”的判断。

用户先确认正常重启输入法可恢复中文，随后明确复现：Chrome 密码框输入后离开，再进微信，增强版变灰。现场 `IsSecureEventInputEnabled()` 持续为 true，跨应用不释放。用户回到原 Chrome 密码页面按 ⌘L，再回微信后立即恢复；这期间输入法没有重启，系统安全输入变为 false，增强版 Hans 被选中，微信 controller 活跃。

已安装 Chrome 为 156.0.8078.81。对照其对应版本源码与 Chromium 已合并修复：失去窗口焦点后 `HasFocus()` 返回 false，旧 `SetActive(false)` 因这个条件跳过 `SetTextInputActive(false)`，导致密码输入保护没有释放。对应上游修复为 [Chromium CL 8681398](https://chromium-review.googlesource.com/c/chromium/src/+/8681398)，问题编号 577708579；引入焦点行为的更改为 [CL 7085807](https://chromium-review.googlesource.com/c/chromium/src/+/7085807)。[本机对应版本源码](https://github.com/chromium/chromium/blob/156.0.8078.81/content/browser/renderer_host/render_widget_host_view_mac.mm)和[修复提交](https://chromium.googlesource.com/chromium/src/+/998a3a35d72973ec86b288064cd2bc920b646d4b)可独立检查。

系统的 `kCGSSessionSecureInputPID` 会随前台应用变化，本次出现 Chrome、微信及计算器等不同归属值，不能将它单独当成真实占用者。记录器现改用 `systemAttributedPID` 字段，明确这是系统归属信息，需用前后对照确认因果。

## 已实施

- 正常退出并重新启动 Chrome，实际主进程带有 `--disable-features=RWHVMacHasFocusReturnsFalseForNonKeyWindow`。这是恢复旧焦点行为的兼容措施；未关闭安全输入功能，没有修改 Chrome 二进制、密码库、浏览器 Profile 或网站内容。
- 安装独立的“Chrome 输入法兼容启动”GUI 入口，并提供桌面入口。若 Chrome 已运行且没有该参数，工具只提示先正常退出，不强杀浏览器、不声称参数已生效。
- 用户明确同意后，安装 `local.squirrel.ChromeIMECompatibility` 登录项。它在登录时以该参数后台启动 Chrome，没有 KeepAlive，不会在用户主动退出后无限重开。
- 输入法增加受保护的系统目录安装，校验目录和程序的 root 所有权及写权限，保留原个人数据目录和引擎独占锁。迁移先退役用户目录程序再发布系统注册，防止旧副本在间隙重启并抢占引擎；失败保留并恢复旧应用。

系统目录迁移后，本次 Chrome 路径仍曾复现，因此迁移本身不是上述浏览器缺陷的修复。此前将安装位置当成可能规避方案的假设已被本机对照否定；真正有效的措施是 Chrome 兼容启动。0.1.43 的公开安装包只安装输入法，不会自动替其他用户修改浏览器启动方式。

## 验证与数据保留

- 48 项启动准入、18 项原安装事务、7 项系统迁移检查通过。新迁移测试包含“旧用户副本须在系统注册前退役”、首装注册失败恢复用户程序、已有系统程序回滚、取消退出及进程未退出等边界。OS 注册与 root 权限在这些夹具中是测试替身，不代替真机结果。
- 21 项保护策略、40 项只读记录器夹具，以及 12 项真实签名 IPC 与 11 项配置检查通过。完整 arm64 构建、包重解包、签名和文件一致性检查、14 项选词及 6 个空白数据默认方案检查通过。
- 本机标准 Installer 安装成功后，额外核验实际运行路径，正常退出迁移间隙重新启动的旧副本，确保运行的是 `/Library/Input Methods/SquirrelEnhancedDev.app` 的 0.1.43。
- 本机完整保留原 SharedSupport 的 63 个文件；语音 Helper 继续使用已授权的 0.1.42，其全部文件、签名及代码身份逐一保持。没有读取或导出密钥值，用户最终语音输入通过。
- 词库、学习数据库和设置未重置。重启过程中 Rime 的 installation/user 状态文件和学习库日志会更新；设置随后从原 revision 43 前进到 45，不能把最终设置文件宣称为逐字节未变化。随包资源逐文件未变化，原 API Key 继续可用。
- 用户最终在启用 Chrome 兼容参数后确认两次“测试密码框 → 微信”中文输入及语音均正常。自动化对后台标签页的 focus 不等于真实前台切换，不单独计作这项硬件验收。

## 日常使用、撤回与边界

当前 Chrome 进程和登录启动配置均已带兼容参数。若手动完全退出 Chrome，后续请从桌面的“Chrome 输入法兼容启动”重新打开。若绕过此入口直接启动原 Chrome，修复参数可能缺失；工具会在下次使用兼容入口时提示。

将来稳定版包含官方修复并通过同样的密码框往返测试后，可撤回兼容参数。移除登录项：

```sh
launchctl bootout gui/$(id -u)/local.squirrel.ChromeIMECompatibility
# 随后把 ~/Library/LaunchAgents/local.squirrel.ChromeIMECompatibility.plist
# 与 ~/Applications/Chrome 输入法兼容启动.app 移入废纸篓即可。
```

本次未注销或重启电脑；登录项静态配置、加载及当前 Chrome 参数已核验，完整开机链路尚未实测。只读状态记录器继续保留最多 48 小时的有限轮替元数据，不采集输入正文、密码、音频或 API Key；关闭入口为 `python3 tools/input_source_audit/manage.py stop --apply`。

本次“Chrome 密码框 → 微信”因果链已闭合。2026-10-30 最初输入源从菜单消失的事件缺少触发前快照，不能追溯宣称当时也一定是同一原因。
