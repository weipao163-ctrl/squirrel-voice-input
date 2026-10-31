# 输入源保护（用户显式启用）

本机保护器只恢复已配置的增强版输入源入口，不切换当前输入法，不安装缺失的应用，不读取正文、录音、词库或凭据。它每 30 秒检查一次；连续两次缺失且相隔至少 10 秒才尝试修复，失败后至少等待 5 分钟。安全输入、锁屏、系统设置位于前台、安装锁或不明确的配置状态都会延后修复。

修复使用 LaunchServices 与 TIS API，并同时校验实时启用列表、实际持久域和首选安装路径。macOS 27 本机观察到 `com.apple.inputsources/AppleEnabledThirdPartyInputSources`；存在该键时（包括空列表）以它为准，否则兼容旧 HIToolbox 域。保护器不写这两个系统偏好域。

```bash
# 默认均为干跑；只读 status 不需要 --apply。
python3 tools/input_source_guard/manage.py install --apply
python3 tools/input_source_guard/manage.py enable --apply --mode Hans
python3 tools/input_source_guard/manage.py status
python3 tools/input_source_guard/manage.py disable --apply
```

`install` 编译并安装 helper，首次默认关闭；`enable` 才创建用户 LaunchAgent。启用期间，从系统设置移除增强版后，离开设置会重新恢复它。需要主动移除/停用时先执行 `disable`，它保留输入法、设置和词库，仅关闭保护并移除自身 LaunchAgent。更新前配置及 LaunchAgent 备份在保护器目录的 `backups/`。

本机目录：`~/Library/Application Support/SquirrelEnhancedDev/input-source-guard/`。仅异常修复写入 `events.jsonl`，超过 256 KiB 后保留一份轮替日志。`state.json` 存储去抖与限流时间；`run.lock` 使用内核文件锁，进程异常退出不会留下死锁。

这是针对异常失效的恢复保护，不证明任何特定系统事件的根因，也不能保证绕过系统故障。测试：`python3 tests/test_input_source_guard.py`，仅编译/运行隔离纯策略，不更改真实输入源。
