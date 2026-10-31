# 输入源状态记录器

这是独立的临时诊断程序，不修改或恢复输入法。主输入法无需重启。

记录内容限于输入源 ID、持久输入源白名单字段、前台应用 bundle ID/PID、正式应用路径/版本及同 ID 进程路径/PID、安全输入是否启用及可取得的占用 PID、睡眠/唤醒状态。不会读取输入文字、窗口标题、URL、词库、Keychain 或音频，也不使用辅助功能接口。

运行时始终先查询 enabled-only TIS 列表；不查询 all-installed 列表。持久状态直接只读指定偏好文件，标记 `observation: disk`，可能短暂滞后于系统内存中的设置。现代域的空数组仍是权威；只有现代键确实不存在时才读取旧域。文件存在但不可读或损坏时报告异常。

输入源、前台应用、目标进程及睡眠通知触发采样，另有 30 秒兜底。只有状态变化、异常变化和启动/停止/到期记录会写入日志。日志目录为 `~/Library/Application Support/SquirrelEnhancedDev/input-source-audit`，目录权限 0700，日志 0600；每个日志最多 1 MiB，共最多 3 个文件。这是最近记录的环形存储，不保证保存完整 48 小时历史。

管理命令默认仅预览：

```sh
python3 tools/input_source_audit/manage.py install
python3 tools/input_source_audit/manage.py start
python3 tools/input_source_audit/manage.py stop
python3 tools/input_source_audit/manage.py status
```

`install --apply` 只编译安装记录器；`start --apply` 单独启用，最多运行 48 小时；`stop --apply` 立即停止并移除本记录器的 LaunchAgent，保留日志。再次明确 start 会开始新的 48 小时会话。LaunchAgent 没有 KeepAlive 或 StartInterval，到期进程退出，不循环启动；status 仍显示 expired。

已安装二进制的 `--snapshot` 仅向 stdout 返回一次当前元数据，不创建目录/锁/日志。`--run` 只有存在有效、已启用且未过期的管理配置时才记录。安装和 start 均不操作输入源。

验证：`python3 tests/test_input_source_audit.py` 只运行注入元数据/临时文件夹具以及管理命令 mock，不运行真实采样器。完整 Swift 编译和未定义符号检查属于离线核验，真实通知交付需另外观察。
