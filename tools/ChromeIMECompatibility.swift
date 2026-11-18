import AppKit

// Chromium's focused-window regression, crbug.com/577708579. Restore the
// previous focus behavior, retaining Secure Input inside password fields.
let feature = "RWHVMacHasFocusReturnsFalseForNonKeyWindow"
let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func hasCompatibility(_ pid: pid_t) -> Bool {
  let task = Process(), pipe = Pipe()
  task.executableURL = URL(fileURLWithPath: "/bin/ps")
  task.arguments = ["-p", String(pid), "-o", "command="]
  task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
  do { try task.run() } catch { return false }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  task.waitUntilExit()
  // Inspect command-line switches only in memory. Never log URLs or arguments.
  guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else { return false }
  return text.split(whereSeparator: \.isWhitespace).contains { argument in
    guard argument.hasPrefix("--disable-features=") else { return false }
    return argument.dropFirst("--disable-features=".count).split(separator: ",").contains(Substring(feature))
  }
}

if NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").contains(where: { !hasCompatibility($0.processIdentifier) }) {
  let alert = NSAlert()
  alert.messageText = "请先正常退出 Chrome，再打开此入口"
  alert.informativeText = "Chrome 已经运行，启动参数只能在完全退出后生效。请先保存未提交的网页内容，从 Chrome 菜单选择退出，再打开“Chrome 输入法兼容启动”。不会强制退出浏览器，也不会修改密码保护。"
  alert.addButton(withTitle: "知道了")
  app.activate(ignoringOtherApps: true)
  alert.runModal()
  exit(0)
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.arguments = ["--disable-features=" + feature, "--restore-last-session"]
NSWorkspace.shared.openApplication(at: chrome, configuration: configuration) { _, error in
  if let error {
    let alert = NSAlert()
    alert.messageText = "Chrome 未能启动"
    alert.informativeText = error.localizedDescription
    alert.runModal()
  }
  app.terminate(nil)
}
app.run()
