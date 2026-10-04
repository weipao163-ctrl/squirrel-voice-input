# 架构

| 目录 | 责任 |
| --- | --- |
| `enhanced-squirrel/sources/` | Squirrel 前端、IMK 生命周期、Rime 提交、候选窗口、增强桥接和目标校验 |
| `enhanced-squirrel/Enhancements/Sources/EnhancementCore/` | 设置、按键/识别状态机、服务协议、PCM 策略、事务与草稿模型 |
| `enhanced-squirrel/Enhancements/Sources/EnhancementIPC/` | 同用户与进程/签名身份绑定的进程间通信 |
| `enhanced-squirrel/Enhancements/Sources/VoiceHelper/` | 设置界面、Keychain、权限、音频捕获和云识别连接 |
| `lua/`、`config/` | Rime 两阶段字母选词及增量补丁 |
| `tests/`、`tools/` | Lua、Swift Core、原生夹具、安装与构建验证 |

语音流程为热键按下 → 固定配置与设备 → 验证目标 → 采音和识别 → 松手并排空音频 → 再次验证目标 → 原生提交或保留草稿。完整结果到达前不会把每句中间识别直接写入目标。

普通拼音通过 IMKTextInput 交互。语音首先校验辅助功能输入元素、窗口、可编辑性与选区；宿主明确不提供部分 AX 属性时，在限定条件下使用同一 IMK 会话、光标矩形及宿主所属窗口快照。Finder 文件名的已知非空选区另做范围/身份校验。

权限拒绝、超时、失效对象、安全输入或未知替换范围不进入宽松兼容。普通键盘/鼠标、切换应用/窗口、输入源/会话变化会撤销自动提交资格。最终结果仍走原生键盘提交路径，不用全局粘贴替代定位。

Helper 和主程序须使用匹配的签名身份；ad-hoc 构建不能假装具备生产语音 IPC。配置事务和独立数据目录用于保护已有设置及词库。
