# 0.1.35 源码复查与边界修复报告

本轮确认并修复两处运行时边界缺陷及一处开发打包工具缺陷；已编译完整 Apple Silicon 安装包并更新本机。2026-10-21 经维护者授权，将源码、完整安装包和本报告发布至 GitHub；下文的源码审查与组件验证发生于 2026-10-16。没有采集麦克风、上传音频或发起云识别；没有把本机词库用于公开构建，也没有读取或修改 Keychain 值。

## 范围与方法

从现有未提交的 0.1.34 修改继续，开始前保留完整差异快照，未重置或覆盖原有修复。本轮按文件逐段阅读 60 个生产 Swift 文件（约 1.07 万行），覆盖主输入控制器、候选绘制/定位、原生语音目标、Helper、热键/音频、三种 ASR 协议、设置和双向认证 IPC；另读原生选词工作程序、Lua 选词、桥接头，以及主要构建、安装、迁移和公开包边界工具。逐文件路径、行数和 SHA-256 记录于 E-12。

不是对整个依赖生态作“零漏洞”保证：未逐行审计 vendored librime、Boost、LevelDB、Lua、OpenCC、Sparkle 或 macOS 系统实现。公开词表核验来源和哈希，不逐条评估词义；测试工具只对本轮使用/相关部分复查。环境没有 Semgrep/CodeQL，本轮使用手工审查、风险模式检索和生产代码隔离回归，不将其写成 SAST 扫描通过。

主要数据边界：

| 入口 | 复查重点 | 结论与限制 |
| --- | --- | --- |
| IMK 按键、客户端和窗口回调 | 首键暂存、会话代次、显示归属、坐标缓存、提交时复核 | 93 项生产控制器回归通过；不据此保证所有宿主/系统版本的偶发现象已覆盖 |
| Rime 候选、注释、配置 | 文本与模板分离、范围、点击区域、Lua 数字/字母行为 | 发现并修复 F-1；数字回归 32 项通过 |
| WebSocket 和 ASR 结果 | 帧长度、压缩输出上限、序号、结束/失败状态 | 发现并修复 F-2；仍保留 256 KiB 包预算和解压边界 |
| 设置、Keychain、音频设备 | 文件事务、敏感值不落普通设置、设备失效恢复、PCM 转换 | 本轮未发现新的已确认缺陷；没有读取真实 Key 或云鉴权 |
| 本机 IPC、语音投递 | 对端身份绑定、旧会话拒绝、安全输入、目标变化 | 12 项认证 IPC、11 项配置、106 项目标检查通过 |
| 安装、构建和迁移 | 事务回滚、协作退出、公开资源来源、个人数据隔离 | 发现并修复 F-3；安装事务 9 项、协作更新 4 项、源码边界测试 11 项通过 |

## 已确认问题及修复

### F-1：候选词中的模板字样被再次替换

- 状态：validated，已修复；严重程度：low，显示正确性；证据：E-1、E-2。
- 位置：`enhanced-squirrel/sources/SquirrelPanel.swift`，`update` 内候选格式展开。
- 触发：格式为 `[label] [candidate] [comment]`，候选原文为 `[comment]`，注释为“注释”。旧版实际绘制 `a 注释 注释`，而候选本身仍是 `[comment]`，可能造成显示与选择结果不一致。
- 根因：先展开候选，再对整个结果替换注释占位符，误把插入后的普通文字当成模板。
- 修改：仅匹配原模板中的占位符，按原范围从后向前替换；插入的候选、标签、注释只作为文本。缩进宽度也只由原模板的标签前缀计算。
- 复验：两个合成候选在旧源代码下失败，修复后均逐字符保留；21 项实际 AppKit 绘制/命中/主题检查全部通过。测试读取 TextKit 2 的内容存储，不依赖空的兼容 `NSTextView.string`。
- P-1 调用链：Rime 候选 → `SquirrelPanel.update` → 原模板替换 → TextKit 2 显示。E-1 证明旧输出被改写，E-2 证明修复后保持原文；没有改变选词/上屏通道。

### F-2：豆包解码器错误假设 Data 从下标 0 开始

- 状态：validated，已修复；严重程度：medium，边界输入导致进程异常；证据：E-3、E-4、E-5。
- 位置：`enhanced-squirrel/Enhancements/Sources/EnhancementCore/DoubaoProtocol.swift`，`response`。
- 触发：在有效协议帧前放 16 字节，再 `dropFirst(16)` 将有效数据切片传入解码器。切片有足够字节，但首个有效索引仍为 16。旧版进程退出码 -5，修复版正常解码“公开测试”。
- 根因：用 `count` 检查长度，却用固定 `[0]`、`[1]` 和从 4 开始的绝对下标读取；Swift Data 切片保留原索引。
- 修改：头部/游标使用 `startIndex`，剩余长度用 `endIndex - offset`；不增加整包复制，不放宽帧验证或解压限制。
- 复验：新增偏移 1/16/257、截断、无效头、压缩切片检查；165 个 Core 测试体全部通过。测试通过原生 Swift Testing 断言适配运行原 Core XCTest 测试体，不冒充 Xcode XCTest 全套环境。
- P-2 调用链：调用方提供 Data → `DoubaoProtocol.response` → 帧头/序号/长度 → 解压/JSON。E-3/E-4 为独立进程前后对照，E-5 验证错误输入正常抛错。
- 限制：这是隔离构造输入证实的潜在缺陷，当前 `URLSession` 正常网络帧未观察到该切片形态。不能认定它是此前偶发语音中断的根因。

### F-3：旧 ZIP 工具把不完整清单与完整构建清单比较

- 状态：validated，已修复；严重程度：low，开发工具误报；证据：E-6、E-7。
- 位置：`tools/package_macos_app.py`，解包后的 `hashes` 校验。
- 根因：旧工具固定校验四份程序/库；当前构建证明还有三份公开预编译词库，共七项，因此字典比较恒为 false。
- 修改：按当前构建证明的完整键集合，从真实解包目录逐一计算哈希，不通过缩小构建清单规避校验。
- P-3 调用链：已验证 App → ZIP → 新目录解包 → 七项哈希、签名及真实 Rime 工作者检查；E-6 证明原集合不相等，E-7 为实际 ZIP 解包 PASS。
- 限制：这是旧开发工具，不是目前 `.pkg` 安装流程的失败原因。一次性 ZIP 仅留在忽略的本地审查证据目录，不作为新的用户交付物。

## 验证与复验

| 检查 | 本轮结果 |
| --- | --- |
| Core | 165/165 测试体通过，包含非零索引/截断/压缩切片 |
| 原生候选 AppKit | 21/21；原模板文字缺陷旧版失败 2 项，修复后通过 |
| 生产键盘控制器 + 实际 librime | 93/93，含旧窗口恢复、迟到回调、首键和位置恢复 |
| 数字/字母选词实际 librime | 32/32，新增已确认分段边界退格覆盖；此新增案例旧版也通过，不计为修复 |
| 原生目标与 IPC | 106 项目标；12 项签名 IPC 和 11 项配置检查通过 |
| 合成音频 | 24/24，不访问真实麦克风 |
| 安装/更新/源码边界 | 9 + 4 + 11 项通过 |
| 完整 PKG | 重新解包、签名、脚本及程序比对、14 项字母行为、6 个空白用户目录默认方案通过 |
| 本机更新 | 0.1.35 已安装、重新启用；完整签名通过，原 SharedSupport 63 文件保留 |

先按 `BUILDING.md` 完成本地构建，再从源码根目录复验：

```bash
python3 tools/run_macos_core.py --report evidence/core-review.json
python3 tools/run_native_candidate_panel.py
python3 tools/run_native_keyboard_input.py --label audit-review
python3 tools/run_native_voice_target.py
python3 tools/run_native_ipc_trust.py
python3 tools/record_macos_build.py
python3 tools/build_macos_installer.py
```

F-1 对照使用仓库 `v0.1.33` 的 `SquirrelPanel.swift` 副本配合当前 `NativeCandidatePanelProbe.swift` 独立编译；保持生产文件不动。F-2 的长期回归位于 `testDoubaoDecoderSupportsNonzeroDataIndicesAndTruncatedSlices`。私有审查目录还保存一次性独立进程探针；报告中的相对证据路径只存在于本机，第三方可通过上述测试重建验证，不会随公开源码上传。

排除项：Foundation 工作空间标识换行边界实际均被拒绝，未改；零圆角加背景扩展的路径有限性检查在修复前已通过，未改绘图算法。这些不列为 bug。

## 性能与数据保护

本轮没有增加常驻定时器、按键 AX/坐标查询或联网动作。候选格式解析只在已有绘制过程执行；解码器只调整索引运算。12000 对按下/松开隔离工作量的 keyDown P95 约 0.036 ms；隐藏候选时几何查询仍为 0。该值是生产控制器测试夹具的回调耗时，不是微信/WPS 物理键盘到屏幕的延迟；本轮不据此宣称真实内存或 CPU 已进一步下降。

安装前后、重新启动前核对 470 份受保护文件哈希：正式 Rime、增强版 Rime、设置及原 SharedSupport 全部一致。重启后 Rime 运行元数据和学习数据库可正常轮换。为保留本机自定义词库资源，本机 App 使用独立暂存副本保留旧 SharedSupport 后重新签名；前端签名因此与公开构建不同，但移除签名的程序代码完全一致，Helper 和原生工作程序逐字节相同。未读取、导出或改写 Keychain。

当前工作区的 247 个待分发源码文件在独立副本中通过路径与凭据扫描，未发现违规项。公开构建仅使用固定公开资源，并核验 PublicPinyin 来源、许可和哈希；安装包不包含个人词库、用户学习数据库、用户设置或预置 API Key。最新完整本地包为 `SquirrelVoiceInput-0.1.20261016.35-arm64.pkg`，大小 53590081 字节，SHA-256：`8654aebd55782406350d68c58be41121ff906b03012872d6eaeb72835b6a451c`。仍为本机证书签名，未经过 Developer ID 签名/Apple 公证；首次安装的系统放行说明继续适用。

没有在这轮审查重新操控微信/WPS 的真实编辑框，也未复现用户历史偶发现场；旧窗口的 93 项隔离回归通过与真实应用长期稳定性是不同层级。此报告不承诺“以后不会再有 bug”。

## 三条建议

1. **把宿主兼容性变为固定发布门槛。** 为微信、WPS、浏览器和 Finder 固定覆盖久未激活、切窗、全屏、首键及断续坐标场景，同时设置输入耗时/内存基线。每次修改必须回归这一组场景，降低只针对当前故障修补而遗漏旧路径的概率。
2. **增加一键脱敏诊断导出。** 让用户在故障时保存最近的会话状态、显示归属、版本和耗时计数，默认不记录输入正文、音频、按键序列和 Key。当前内存统计已有基础，补一个设置页入口可减少偶发问题恢复后无法定位的情况。
3. **完善正式签名、公证与可回滚更新。** 将版本、来源和安装校验统一展示，签名/公证及干净机器验证作为正式发布条件，降低首次安装和升级成本。需要开发者账号和另一次明确实施安排，本轮没有购买账号或更改发布流程。

## 证据索引

证据基目录：`evidence/source-audit-0.1.35/`（忽略，不上传）。全部为本轮本机命令/文件观察，采集日期 2026-10-16。E-3 对照保留独立进程异常退出事实；并非真实语音崩溃日志。E-1/E-2 使用合成候选内容，不包含用户输入。

| Evidence | 文件 | SHA-256 |
| --- | --- | --- |
| E-1 | `panel-baseline.json` | `d8fe498db7f070ae307101594c5c0970922eecd0eba13f060f5255fe869c473a` |
| E-2 | `panel-final.json` | `f5cfb7793db648de2c6a163e1b371ba932273e6c3bfe53267787e2b6ca4de99d` |
| E-3 | `doubao-slice-baseline.json` | `12b05bfcadc6d9d6b712287c32286789b1b1452f42ac739a480b282b1ecfa382` |
| E-4 | `doubao-slice-fixed.json` | `bdb4b4650c6800d8c86605b9f12f430ec72395302d97af75a6d2b2c82f75ccf0` |
| E-5 | `core-final.json` | `1fc1cd014d7bbb59edb6eb0831575d5205a70baec3fc888853f008942f13c69f` |
| E-6 | `zip-manifest-baseline.json` | `5d187fe6a246a566eba2d2a67f7c82a65f98688cd9b101748fdf08b6b2a89ed1` |
| E-7 | `macos-binary-smoke.json` | `08def14c150abedbcc412ed457e717c377cfb9337ee64ad2adb15d63d72c7ed6` |
| E-8 | `source-audit-35.json` | `c9cb0106340e84dc120d9a831eb4b6b1f96b2c5e1d196791bf285447d37d9d3d` |
| E-9 | `macos-native-voice-target.json` | `b592c0a193a539723e99fda889cb9db72efd2bbcf7872abd1068a5c17128b0ac` |
| E-10 | `macos-installer.json` | `82b11aa835deb4659bf46781d45ef69c3747630cb8fc3e1b331f575f1a287a0e` |
| E-11 | `local-install-verification.json` | `a756a2493d81701b6bc5d942c4d320ac2b6c09c869dddf884e66273e26f34d4d` |
| E-12 | `review-ledger.json` | `4630d7ffab0f43e3edf337b03ad1d03e967236a2567fba43c6dea41abaf8cd8b` |
