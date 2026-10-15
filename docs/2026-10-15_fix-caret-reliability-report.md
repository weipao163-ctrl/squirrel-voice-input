# 0.1.33：提高候选窗定位可靠性

本版沿用输入法当前原生会话，提高短暂坐标不可用时的恢复能力。适用于所有宿主，不为微信、WPS 或某种控件添加名单。候选窗的显示坐标不决定文字插入目标。

## 证据、发现与修改路径

E-1/E-2 → F-1 → P-1：旧 `validCaret` 拒绝负宽度，但 Apple 的 `NSTextInputClient.firstRect` 明确允许反向矩形。现在先检查原始分量有限且高度非零，再标准化矩形并检查屏幕交集；零宽度插入点仍有效，零矩形和离屏/非有限坐标仍拒绝。保留 attributes 的 inline index 0 与 selectedRange 的文档位置两条查询，不猜文档偏移，不把屏幕回退冒充光标。方向矩形负对照在原生目标夹具中验证。它是已确认的兼容缺口，不是已经证明的微信每次偶发根因。[Apple 原生接口说明](https://developer.apple.com/documentation/appkit/nstextinputclient/firstrect(forcharacterrange:actualrange:))。

E-1 → F-2 → P-2：旧实现每次候选更新都取消并重新开始重试。现在候选内容与几何恢复分别合并：立即呈现最新内容，同时保留本轮有限重试的进度。新客户端代理会撤销旧请求，避免旧工作占用新会话的调度槽。按键回调不执行几何或 AX 调用；隐藏候选也不重复清理空的监听/缓存。约一秒的有限重试耗尽后停止空闲查询，下一次可见内容更新可重试；宿主自身 IPC 时间另计。

E-1 → F-3 → P-3：原生查询失败时，使用已有 AX 授权，异步读取前台应用的焦点对象、窗口、`AXSelectedTextRange` 与 `AXBoundsForRange`。每个 AX 对象单独设置 35ms 消息超时；整轮约 200ms 时间预算，最后一项调用可能额外占用一次超时。进程内最多一个在途任务，每个恢复器最少间隔 180ms，不随按键积压任务。主线程不等待 AX，也不读取正文或选中文字。完成前复核同一焦点、窗口、范围、窗口框架，回主线程后再校验活动控制器、客户端、输入代次、前台进程和屏幕布局。参考 [AX 范围边界](https://developer.apple.com/documentation/applicationservices/kaxboundsforrangeparameterizedattribute)、[逐对象消息超时](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)。

E-1 → F-4 → P-4：独立 AX 焦点/窗口/选区监听完整可用时，才允许最多 180ms 的显示缓存，读取不会续期；监听不完整则只使用当次新鲜坐标。鼠标、滚动、导航、失焦、会话变化、Space 和屏幕变化撤销旧展示/缓存；AX 焦点、选区、窗口移动/缩放、对象销毁使缓存租约失效。仍无法取得坐标时显示屏幕下方中央的候选窗。所有路径继续使用原 IMK 客户端提交文字；语音目标验证只使用真实原生证据，不接收此显示缓存或屏幕回退。

## 自动检查

最终生产控制器的 79 项检查全部通过：原有 56 项，增加客户端代理轮换、连续内容更新不重置预算、单 AX 任务、缓存期限/应用边界、焦点抖动、迟到结果、AX 恢复、原生结果优先等。慢速 AX 传输与时钟由受控依赖注入，生产状态机、面板及真实 Rime 仍执行实际代码。夹具不将用户在真实应用中的鼠标或切换活动当作测试事件。

另有 106 项原生目标、18 项实际 AppKit 面板、164 项 Core 断言体、12 项真实签名 IPC、各 11 项配置和启动边界、12 项新用户默认字母设置检查通过。Core 使用真实 Swift Testing 执行保留的 XCTest 断言体，不称为原生 XCTest 真机验收。安装包重新展开核对真实二进制、签名及安装脚本，14 项字母行为与全部 6 个默认方案在空白数据目录通过。

本机原始证据留在被忽略的 `evidence/`，不随公开仓库发布；公开证据摘要只含脱敏计数与哈希。

| Evidence | 报告 SHA-256 |
| --- | --- |
| E-1: 79 项键盘/恢复检查 | `69c29223e41bc83ceb83a43755a96247c525c929fc1a91eafe7cd188465c723c` |
| E-2: 106 项原生目标检查 | `fb0dd5330487bb8e7b1411da5f12d6ed43fa65bcf4c78177e65ac07d9cca353c` |
| E-3: 18 项 AppKit 面板检查 | `cf6966779cc47813f9d1b42b17120228040d436bc505a1ca70a2959ab7223dc2` |
| E-4: 三组交替性能对照 | `73b1dbe603aa70f858e70f9e65e8b4dd1db7879479c25897edf1e12cada3d93a` |
| E-5: 包内公开资源集合对照 | `2c7f0c8f69d13d53fe7d29935f81806de0339621d5e23dfd2729829586837a15` |
| E-6: 本机最终替换事务 | `cbcfe39ebdb7f905fb097eb1c30e7ef271a9babcbdbd138aceadd79550fcd27a` |
| E-7: 微信四轮实际键盘输入 | `8f97525418e30a962b72d20b7cda4152a0a84ab3a881957dcb2b0db09a88e101` |
| E-8: WPS 单元格/公式栏/查找框实际输入 | `da2d6a11fb3188abe329d851469e9eb80ed6738a9fa522304d7143a3f5d62ccb` |

复验（先按 BUILDING.md 完成构建）：

```bash
python3 tools/run_native_keyboard_input.py --label caret-reliability
python3 tools/run_native_candidate_panel.py
python3 tools/run_native_voice_target.py
python3 tools/run_default_letters.py --app enhanced-squirrel/build/CLT/SquirrelEnhancedDev.app
python3 tools/run_native_ipc_trust.py
python3 tools/record_macos_build.py
python3 tools/build_macos_installer.py
```

可使用 `--controller-source` 加载 v0.1.32 控制器作原有 56 项对照；新增恢复检查只在包含新恢复器的生产控制器中启用。断言不因运行旧版而改成成功。

## 性能范围

E-4 → F-5：候选与浮动预编辑均隐藏的热路径仍为零次几何查询、零次 AX 调用；三个交替轮次分别执行同一隔离词库、同一 `nihao` + Esc 工作量，每次 12,000 次 keyDown 和 12,000 次 keyUp，均为 `-O`。结果未观察到普通按键处理退化；数值为三个轮次的中位数，受系统调度影响。

| 指标 | 0.1.32 对照 | 0.1.33 |
| --- | ---: | ---: |
| 按键回调 P50 | 0.02817 ms | 0.02808 ms |
| 按键回调 P95 | 0.03867 ms | 0.03812 ms |
| 每对 down/up 的 CPU | 0.03444 ms | 0.03399 ms |
| 持续输入后夹具进程 footprint | 27.24 MiB | 28.00 MiB |

本次夹具进程的观测占用约增加 0.77 MiB，持续输入/500 次激活的资源检查有界；统计仅保留最多 64 个耗时样本和固定来源计数。此处是生产控制器在隔离宿主/小词库中的处理耗时，不是物理按键到微信/WPS 绘制完成的端到端延迟，也不能推算全部公开或个人词库的进程占用。

## 微信、WPS 与本机交付范围

微信解锁后已在真实聊天输入框完成四轮 `ni` → 空格 → 字母 `a`，实际 AX 值均为“你”，随后逐次清除，未发送消息。生产面板在组合中可见、清除后隐藏，原生 attributes 坐标有效；前台/目标复核通过。微信本次未返回 AX 选区边界，正常使用原生通道，不能声称已在微信现场复现或测量了 AX 补偿成功率。WPS 空白单元格累计完成两轮、公式栏与查找框各一轮同类输入，组合中面板可见，原生 attributes 坐标与前台/目标复核通过；测试文字已清除，A1 和查找框恢复为空，未保存文档。WPS 本次同样未提供 AX 选区边界。原先的偶发失败在本轮未重现，真实应用的 AX 补偿成功率尚未测量。

已增加显式只读诊断 `--candidate-position-check`，在前台普通文本框中分别返回原生/AX 坐标可用性；`--candidate-position-stats` 返回内存计数、是否显示候选及最近来源。两个命令都不录音、不调用云服务、不读取正文、不插入文字，不保存使用日志。未选中普通输入框时返回不可用不代表该应用不能输入。

App/Helper 为 0.1.33，完整 Apple Silicon 包为 `SquirrelVoiceInput-0.1.20261015.33-arm64.pkg`，SHA-256 为 `6820264147ec147300286a8c5e148cc15c3d7af418ddaab12e89f005339ec845`。包内 269 个文件/链接的集合与前一公开包一致，261 个内容不变，仅 8 个声明的二进制、版本、签名与公开预编译资料改变；公开词表仍为固定来源的 1,873,509 条源字词记录，没有新增本机个人资源。

本机最终事务保留原 SharedSupport 的 63 个文件；替换前后 250 个用户数据文件哈希一致。没有读取 Keychain 值，也没有用公开词表替换本机词库。替换后正常学习、日志或缓存可以继续变化。公开源码与包排除个人词库、学习数据、设置、API Key 和签名私钥。

包的依赖闭包检查通过；当前仍为本地证书签名、未经过 Apple Developer ID 签名/公证，新电脑首次安装需在“系统设置 → 隐私与安全 → 仍要打开”手动允许，见[安装说明](INSTALLATION.md)。本次未在第二台 Mac 真机安装，也不宣称所有应用或全屏场景已经全部验收。
