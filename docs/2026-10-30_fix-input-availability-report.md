# 0.1.40：输入源可用性与语音凭据恢复修复

2026-10-30。最终已安装主程序与 Helper 0.1.40，输入源保护已启用。**用户最终确认“中文和语音都正常”；原设置、词库及 API Key 保留。当前无需注销。已修复本次发现的注册判断和凭据读取恢复缺陷；输入法最初消失的精确系统触发事件仍不能完全归因，长期永不复发不是已验证结论。** 本次未发布 GitHub。

## 当前证据与根因边界

- 首次检查主程序及 Helper 仍在运行，签名通过，没有发现对应崩溃记录。正式安装路径是 LaunchServices 首选，因此没有复现昨天“首选路径指向构建副本”的状态。
- 用户确认消失前只在正常打字；重新添加后截图显示增强版变灰，不能选中。程序存在、注册存在或 TIS API 返回 noErr，均不等于前台输入服务可用。
- 初期仅检查 `com.apple.HIToolbox` 曾误判启用名单被删除。后查明本机 macOS 27 使用 `com.apple.inputsources/AppleEnabledThirdPartyInputSources` 保存第三方名单；14:05:12 系统设置添加后，该域包含父源与 Hans。初始未备份该新域，故不能反推它原先是否丢失。诊断中向旧域临时追加的两个记录已精确撤回，其余旧域记录保留。
- 系统 `imklaunchagent` 在故障窗口及新版启动后出现 `Refusing connection name for bundle: unrecognized 'InputMethodConnectionName' value` 和 EndpointInvalid。Bundle ID 被系统隐藏，不能将每条错误直接归给增强版；结合用户的灰色菜单，故障范围指向输入会话/系统代理连接。当前 Bundle ID、连接名与 bootstrap 端点一致；没有证据证明 IMKServer 已释放。
- Chrome 一度在后台持有安全输入，后恢复为 false；灰色现象仍需单独处理，不能把安全输入直接等同于持久名单丢失。
- 已正常退出旧程序、安装并启动新程序。系统拒绝 `launchctl kickstart -k gui/501/com.apple.imklaunchagent`，返回 150：`Operation not permitted while System Integrity Protection is engaged`。未关闭 SIP，未用其他信号绕过该拒绝，未全局重置 LaunchServices。随后在未注销、未重启系统代理的情况下，用户确认可选中并正常中文输入；实时会话同步恢复。此前要求注销的下一步已撤销，不能据此把系统代理缓存单独确定为根因。

[Apple IMKServer 文档](https://developer.apple.com/documentation/inputmethodkit/imkserver/init(name:bundleidentifier:))说明此服务负责建立输入客户端连接；本次以现场日志和实际截图判断，不把公开文档当作本机故障复现。

## 已落地修复

1. 启用判断兼容新旧系统偏好域，新域存在时（包括空列表）优先；结合真实 enabled-only TIS 列表，不再只相信全量已安装列表的默认布尔值。
2. 显式启用调用父源、再调用指定模式的 TIS API，随后验证保存结果及实时列表。保留 Hant-only 选择；失败返回非零，不直接写系统 plist、不自动禁用或切换其他源。
3. `--input-source-status` 输出读取顺序、两域白名单记录、当前输入源、首选路径及安全输入状态；不采集输入正文、密码或录音。
4. 修复安装事务：`lsregister -u` 对尚未注册的副本/Helper 返回精确 `-10814` 时视为幂等完成；其他错误仍回滚。此前一次升级因此中止，旧 0.1.38 已自动恢复；修复后再次升级成功。
5. CLT 旧构建备份改为 `.app-backup`。新增独立、可关闭的输入源保护，启动登录时运行，此后每 30 秒检查；连续两次缺失才修复，失败后至少等待 5 分钟。健康时不写事件日志；安全输入、锁屏、系统设置前台及安装中延后。它只恢复注册/启用入口，**不代表能自动治愈灰色菜单或系统代理故障，也不自动重启系统服务。**

## 0.1.39 阶段验证

- 输入源生产逻辑 22 项检查、安装事务 12 项、正常退出准备 4 项通过。
- 生产键盘控制器与隔离真实 Rime 的 93 项检查通过。
- 12 项认证 IPC 与 11 项配置检查通过；完整 arm64 包重解包，签名、文件一致性、公开词库、14 项字母选词及默认方案检查通过。
- 保护器生产 Swift 编译通过；3 项 Python 测试覆盖 21 项 Swift 策略、管理干跑、发布失败回滚。实际安装、启用、关闭、再启用成功，launchd 最近退出码 0，30 秒周期已生效，健康状态未执行恢复。
- 本机主程序 0.1.39、Helper 0.1.39，系统首选正式安装路径，新域父源/Hans记录存在。`registration_healthy` 只描述注册健康，不描述 IMK 会话或真人输入成功。
- 文本编辑中自动化按键未形成可确认的增强版中文上屏结果，没有计作验收。用户此前反馈“出现但灰色”，后续在 0.1.39 安装和主程序重启后明确确认“能选中，中文正常”。实时 `active_controller=true`、`client_bundle=com.openai.codex`、当前输入源为增强版 Hans，与用户结果一致。语音曾因新版 Helper 的钥匙串读取未获授权失败；重新校验并授权后，设置页鉴权与连接通过，用户明确确认“能正常语音输入”。程序化检查未采音，真实语音由用户验收。

## 数据与 0.1.39 阶段交付

正式 Rime 的 195 个文件哈希保持一致；安装包内本机 SharedSupport 的 63 个文件逐一保持一致。增强版原有 248 个文件中 241 个不变；其余为 Rime 正常启动/退出更新的 installation/user 记录及 LevelDB 轮转文件，学习数据库仍在原目录，未清空或替换。设置、源词库、Keychain 未重置或导出。

本机更新使用保留既有 SharedSupport 的专用候选。`dist/SquirrelVoiceInput-0.1.20261030.39-arm64.pkg` 是公开默认词库包，保护器单独安装在本机，未嵌入这个 pkg；源码、测试与管理入口已同步到两份项目，覆盖前保留备份并核对上一版来源。包 SHA-256：`28af5f474aabf4292248db845515f7c4d559bb5f281254c9c15f51a8285efd22`。

## 当前真机验收

用户最终在 0.1.40 安装后确认“中文和语音都正常”。当前无需注销或重启。后续若再次出现异常，保留现场并使用新版状态命令和保护日志区分注册缺失与服务连接问题；不要关闭 SIP 或删除词库。

## 保护开关与回滚

保护启用期间，手动从系统设置移除增强版后会被恢复；要主动移除输入法，先关闭保护：

```bash
python3 tools/input_source_guard/manage.py status
python3 tools/input_source_guard/manage.py disable --apply
# 再开启：
python3 tools/input_source_guard/manage.py enable --apply --mode Hans
```

从任一源码项目根目录运行。运行文件与有限轮替日志位于 `~/Library/Application Support/SquirrelEnhancedDev/input-source-guard/`；关闭仅卸载自身 LaunchAgent，保留输入法和所有个人数据。应用回滚副本在 `~/Library/Application Support/SquirrelEnhancedDev/install-backups/`，此次原始诊断和源码覆盖前备份位于被忽略的 `evidence/input-disappearance-20261030/`，不要上传其中本机资料。

## 语音凭据后续排查

用户在中文恢复后报告“没有可用 API Key”。设置文件 SHA-256 与更新前完全一致；两种服务引用均存在，Keychain 只读属性查询均为 status 0，未导出秘密。0.1.38 与 0.1.39 Helper 的签名证书、指定要求与权限一致，但代码哈希随更新改变。

本机 securityd 日志明确记录新版 Helper 的 `ACL partition mismatch`，随后显示原凭据授权提示；14:22:17 首次读取未获得允许，后续热键只见空缓存且不重试。14:41:43 在设置页重新校验后用户允许读取，API 鉴权与服务连接通过，用户确认语音正常。缺陷是临时读取失败被持续误报为没有 Key；不是本次更新删除了 Keychain 记录。

[Apple securityd 源码](https://raw.githubusercontent.com/apple-oss-distributions/Security/main/securityd/src/clientid.cpp)解释本地自签代码使用 cdhash 分区，因此同一签名证书不保证新版无需再次授权。修复不得放宽为所有应用可读、伪造 Team ID 或绕过系统授权。新 Helper 更新仍可能要求用户允许读取原记录，程序应正确恢复和提示。

## 0.1.40 后续恢复补丁

- 保留仅含 OSStatus 的读取错误，不带密钥或引用；未配置、读取中、授权等待和失败分别提示。
- 启动仅加载当前服务；两种服务使用独立队列，切换时按需加载。每个引用仅有一个进行中的读取，UI 超时不撤销迟到授权。
- 明确打开设置、重新校验或新的有效热键触发有界重试（至少间隔 5 秒）。普通窗口重新激活不重试，避免拒绝授权后立即循环弹窗。
- 取消、过期、配置版本不符、忙碌或录键中的请求不触发重读。恢复后不重放原请求，不自动录音，只接受新的完整按压。
- 删除、更换密钥或恢复配置备份时撤销旧缓存与读取标识，旧结果不能回填。

## 0.1.40 最终交付与复验

- 149 项原生 Helper/编辑器/浮窗回归通过，使用假凭据加载、删除、会话与连接，不接触真实 Keychain 或音频；完整构建与测试源码哈希一致。
- 0.1.40 完整 arm64 构建、深度签名、构建来源校验、公开词库检查、完整 pkg 重解包与自测通过。
- 本机正常退出并事务更新；保留既有 SharedSupport 后重签主程序。正式安装路径仍为系统首选，Hans 已启用并选中，保护器注册健康。
- 系统再次请求新 Helper 读取原密钥，用户允许后自动恢复；实际设置页确认 API 鉴权与连接通过。随后用户明确确认“中文和语音都正常”。
- 最终设置 SHA-256 与修复前一致，正式 Rime 195 个文件、本机 SharedSupport 63 个文件哈希一致。增强目录差异仍仅为已记录的正常 Rime 状态及学习库轮转，未清空词库或导出 Key。
- 两份源码项目已同步此修复，覆盖前备份并验证原文件来源；已有独有 runner 修改保留。

最终完整安装包：`dist/SquirrelVoiceInput-0.1.20261030.40-arm64.pkg`。SHA-256：`383f7917c3fb340afb3501e6ede6946228d61025ff51e138a95a6cbaa0f06727`。

保护器继续作为独立本机组件运行，未嵌入公开 pkg；保护开关见上文。真正更新 Helper 仍可能触发系统授权，这是保留钥匙串安全边界的行为；应允许原应用读取原记录，无需重新填写或删除 Key。
