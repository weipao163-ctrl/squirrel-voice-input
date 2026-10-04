import AppKit
import SwiftUI
import EnhancementCore
import ApplicationServices

final class SettingsWindow: NSWindowController, NSWindowDelegate {
  private let model: HelperModel
  init(model: HelperModel) {
    self.model = model
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:760),
                          styleMask:[.titled,.closable,.resizable,.miniaturizable], backing:.buffered, defer:false)
    window.title = "鼠须管增强输入设置（开发隔离版）"
    let hosting = NSHostingView(rootView: SettingsView(model:model))
    // Let the window constrain layout; long Form rows must not expand it off-screen.
    hosting.sizingOptions = []
    window.contentView = hosting
    window.autorecalculatesKeyViewLoop = true
    window.minSize = NSSize(width:620,height:560); window.center()
    super.init(window:window); window.delegate = self
  }
  required init?(coder:NSCoder) { nil }
  func windowShouldClose(_ sender:NSWindow) -> Bool { model.confirmClosing() }
  func windowWillClose(_ notification:Notification) { model.stopSettingsActivity() }
}

struct HoldButton: NSViewRepresentable {
  var title: String
  var action: (GUITestHoldAction) -> Void
  func makeNSView(context:Context) -> PressView { let v = PressView(); v.title = title; v.action = action; return v }
  func updateNSView(_ view:PressView, context:Context) { view.title = title; view.action = action }
  static func dismantleNSView(_ nsView:PressView, coordinator:()) { nsView.tearDown() }
  final class PressView: NSView {
    var title = "" { didSet { setAccessibilityLabel(title); needsDisplay = true } }
    var action: ((GUITestHoldAction)->Void)?
    private var cycle = GUITestHoldCycle()
    private var held:Bool { cycle.activeID != nil }
    private var monitor: Any?
    private var deactivate: NSObjectProtocol?
    private var resignKey: NSObjectProtocol?
    override init(frame:NSRect) {
      super.init(frame:frame)
      setAccessibilityElement(true); setAccessibilityRole(.button)
      setAccessibilityHelp("用 Tab 聚焦后按住空格开始测试，松开停止；Esc 取消。云测试会上传音频且可能计费。不是单击切换录音。")
      setAccessibilityValue("空闲")
      toolTip = "鼠标按住，或 Tab 聚焦后按住空格；松开即停止，Esc 取消。"
    }
    required init?(coder:NSCoder) { nil }
    override var acceptsFirstResponder:Bool { true }
    override var canBecomeKeyView:Bool { window != nil && !isHidden }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { end(); needsDisplay = true; return true }
    override var intrinsicContentSize:NSSize { NSSize(width:260,height:34) }
    override func draw(_ dirtyRect:NSRect) {
      (held ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).setFill()
      NSBezierPath(roundedRect:bounds,xRadius:6,yRadius:6).fill()
      (title as NSString).draw(at:NSPoint(x:8,y:8),withAttributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.labelColor])
      if window?.firstResponder === self {
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let ring = NSBezierPath(roundedRect:bounds.insetBy(dx:1.5,dy:1.5),xRadius:6,yRadius:6)
        ring.lineWidth = 2; ring.stroke()
      }
    }
    override func mouseDown(with event:NSEvent) {
      guard window?.isKeyWindow == true else { return } // No cloud click-through.
      window?.makeFirstResponder(self)
      freshPress(.mouse,repeated:false)
    }
    override func mouseUp(with event:NSEvent) {
      emit(cycle.release(.mouse)); settleRegistrations()
    }
    override func keyDown(with event:NSEvent) {
      let command = !event.modifierFlags.intersection([.command,.control,.option]).isEmpty
      if event.keyCode == 53 { end(); return }
      if event.keyCode == 48 && !command {
        end()
        if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
        else { window?.selectNextKeyView(self) }
        return
      }
      if event.keyCode == 49 && !command && !event.modifierFlags.contains(.shift), window?.isKeyWindow == true {
        freshPress(.space,repeated:event.isARepeat); return
      }
      end(); super.keyDown(with:event)
    }
    override func keyUp(with event:NSEvent) {
      if event.keyCode == 49 && cycle.held.contains(.space) {
        emit(cycle.release(.space)); settleRegistrations(); return
      }
      super.keyUp(with:event)
    }
    override func viewWillMove(toWindow newWindow:NSWindow?) {
      if newWindow == nil { tearDown() }; super.viewWillMove(toWindow:newWindow)
    }
    private func freshPress(_ input:GUITestHoldInput,repeated:Bool) {
      // Hardware state reconciles missed ups while another app had focus. A
      // non-repeat down proves a new cycle of that same source, not a timer.
      if cycle.activeID == nil {
        if !CGEventSource.keyState(.combinedSessionState,key:49) { _ = cycle.release(.space) }
        if NSEvent.pressedMouseButtons & 1 == 0 { _ = cycle.release(.mouse) }
        if !repeated { _ = cycle.release(input) }
      }
      let transition = cycle.press(input,repeated:repeated)
      if case .start = transition { installRegistrations() }
      emit(transition)
    }
    private func installRegistrations() {
      removeRegistrations()
      // Only this app; owned releases survive dragging outside the control.
      monitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseUp,.keyUp,.keyDown]) { [weak self] e in
        guard let self else { return e }
        if e.type == .keyDown && e.keyCode == 53 { self.end(); return nil }
        if e.type == .keyDown && e.keyCode == 49 && e.isARepeat && self.cycle.held.contains(.space) {
          return nil // A cancelled owned hold must not repeat into another field.
        }
        if e.type == .leftMouseUp && self.cycle.held.contains(.mouse) {
          self.emit(self.cycle.release(.mouse)); self.settleRegistrations()
        } else if e.type == .keyUp && e.keyCode == 49 && self.cycle.held.contains(.space) {
          self.emit(self.cycle.release(.space)); self.settleRegistrations(); return nil
        } else if self.cycle.activeID == nil {
          if !CGEventSource.keyState(.combinedSessionState,key:49) ||
              e.type == .keyDown && e.keyCode == 49 && !e.isARepeat { _ = self.cycle.release(.space) }
          if NSEvent.pressedMouseButtons & 1 == 0 { _ = self.cycle.release(.mouse) }
          self.settleRegistrations()
        }
        return e
      }
      deactivate = NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.end() }
      resignKey = NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:window,queue:.main) { [weak self] _ in self?.end() }
    }
    private func emit(_ transition:GUITestHoldAction) {
      needsDisplay = true; setAccessibilityValue(held ? "按钮已按住（结果见测试状态）" : "空闲")
      if transition != .none { action?(transition) }
    }
    func end() { emit(cycle.cancel()); settleRegistrations() }
    func tearDown() { emit(cycle.cancel()); removeRegistrations() }
    private func settleRegistrations() { if !cycle.needsReleaseObservation { removeRegistrations() } }
    private func removeRegistrations() {
      if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
      if let deactivate { NotificationCenter.default.removeObserver(deactivate); self.deactivate = nil }
      if let resignKey { NotificationCenter.default.removeObserver(resignKey); self.resignKey = nil }
    }
    deinit { tearDown() }
  }
}

struct DiagnosticSettingsView:View {
  @ObservedObject var model:HelperModel
  private func metric(_ title:String,_ milliseconds:Double?) -> some View {
    HStack(alignment:.top) {
      Text(title); Spacer()
      Text(milliseconds.map { String(format:"%.1f ms",$0) } ?? "未记录 / 不可比较").textSelection(.enabled)
    }
  }
  var body:some View {
    VStack(alignment:.leading,spacing:12) {
      Text(model.helperVersion).textSelection(.enabled)
      Text(model.applicationState).font(.caption)
      Text(model.productionTargetStatus).font(.caption).accessibilityIdentifier("productionTargetStatus")
      Text("只保留最近一条已接受会话的元信息，默认仅在内存。不会记录 Key、地址、设备名、识别正文、音频、输入框内容或剪贴板；退出即丢弃。清除诊断不删除草稿或凭据，也不影响录音状态。").font(.caption)
      Button("清除诊断") { model.clearDiagnostics() }
      if let value=model.diagnostic {
        GroupBox("实际会话") {
          VStack(alignment:.leading,spacing:6) {
            Text(value.mode == .production ? "生产会话；上屏仍由输入法校验原目标" : "设置页云测试；绝不向外部应用上屏")
            Text(value.revision.map { "已保存配置快照：版本 \($0)" } ?? "使用未保存测试表单快照")
            Text("Helper 状态：\(value.phase.title)")
            Text("计时起点：\(value.origin == .physicalPress ? "前端真实按下时间" : "Helper 本地会话开始（非物理按下延迟）")")
            if let cause=value.stopCause { Text("停止原因：\(cause.title)") }
            Text("失败分类：\(value.failure?.title ?? "此会话未记录失败；不是所有功能通过")")
            Text("前端回执：\(value.delivery?.title ?? "未收到；不能断言文字已经写入")")
          }.frame(maxWidth:.infinity,alignment:.leading)
        }
        GroupBox("分阶段耗时（实际事件边界）") {
          VStack(alignment:.leading,spacing:8) {
            metric(value.origin == .physicalPress ? "按下 → 采音引擎启动返回" : "本地开始 → 采音引擎启动返回",value.startToCaptureMilliseconds)
            metric("WebSocket 打开 → task-started",value.milliseconds(from:.webSocketOpened,to:.taskStarted))
            metric("引擎启动返回 → 首批 PCM 入队",value.milliseconds(from:.captureStarted,to:.firstPCM))
            metric("引擎启动返回 → 首条识别文本",value.milliseconds(from:.captureStarted,to:.firstTranscript))
            metric("停止请求 → Helper 收到",value.milliseconds(from:.stopRequested,to:.stopReceived))
            metric("停止请求 → 新样本截止",value.milliseconds(from:.stopRequested,to:.captureCutoff))
            metric("停止请求 → 转换尾部排空",value.milliseconds(from:.stopRequested,to:.tailDrained))
            metric("停止请求 → task-finished",value.milliseconds(from:.stopRequested,to:.taskFinished))
            metric("停止请求 → 前端处理回执",value.milliseconds(from:.stopRequested,to:.frontendDecision))
          }
        }
        GroupBox("时间线（相对上述起点）") {
          VStack(alignment:.leading,spacing:6) {
            ForEach(VoiceDiagnosticStage.allCases,id:\.self) { stage in
              metric(stage.title,value.stages[stage].map { $0*1000 })
            }
          }
        }
      } else { Text("尚无诊断，或已主动清除；不会把未知阶段显示为零耗时或成功。").foregroundStyle(.secondary) }
      Text("计时只描述观测到的 API/事件边界：采音启动返回不是声学采样到达，首条文本不是浮窗已渲染，finish 请求不是服务端确认，insertText 返回不是宿主写入确认。缺失或顺序不可比较时显示未记录。").font(.caption)
      Text("云识别仅在明确按住时上传音频；取消不能撤回已发送音频。云端留存取决于账户服务条款，不承诺云端零留存。本页不采音、不联网，不自动复制任何信息。").font(.caption)
      Text("识别完成后自动输入目标位置，不增加 Enter、Tab 或发送动作。识别原文不经拼音词库、不擅自简繁转换；目标位置改变或文字含控制字符时保留草稿。").font(.caption)
    }.padding()
  }
}

struct VoiceInputModeSettings:View {
  @ObservedObject var model:HelperModel
  private var isCapturing:Bool { model.recordingKeys || model.testingKeys }
  private var shortcutTitle:String {
    if model.recordingKeys { return "按下要设置的键…" }
    guard let binding=model.draft.voice.binding else { return "点击设置按键" }
    let symbols:[UInt16:String]=[54:"右⌘",55:"左⌘",56:"左⇧",58:"左⌥",59:"左⌃",60:"右⇧",61:"右⌥",62:"右⌃",
      64:"F17",79:"F18",80:"F19",105:"F13",106:"F16",107:"F14",113:"F15"]
    return binding.codes.sorted().map { symbols[$0] ?? "键 \($0)" }.joined(separator:" + ")
  }
  var body:some View {
    VStack(alignment:.leading,spacing:16) {
      Text("语音输入模式").font(.system(size:18,weight:.semibold))
      Divider()
      HStack(spacing:20) {
        VStack(alignment:.leading,spacing:5) {
          Text("长按模式").font(.system(size:18,weight:.semibold))
          Text("按住说话，松手结束").font(.system(size:14)).foregroundStyle(.secondary)
        }
        Spacer(minLength:12)
        HStack(spacing:4) {
          Button { model.keyMode(record:true) } label: {
            Text(shortcutTitle).font(.system(size:18,weight:.medium))
              .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth:.infinity,alignment:.leading)
              .padding(.leading,12).padding(.vertical,10).contentShape(Rectangle())
          }.buttonStyle(.plain)
            .disabled(isCapturing || model.waitingKeyRelease)
            .help("点击后按下并松开要使用的语音热键；Esc 取消，不会开始录音。")
            .accessibilityLabel("设置语音长按键")
            .accessibilityValue(model.recordingKeys ? "正在等待新按键" : model.draft.voice.binding?.label ?? "未设置")
            .accessibilityIdentifier("voiceHotkeyRecorder")
          if model.draft.voice.binding != nil || isCapturing {
            Button {
              if isCapturing { model.finishKeyMode(cancel:true) }
              else { model.clearVoiceBinding() }
            } label: {
              Image(systemName:"xmark.circle.fill").font(.system(size:17)).foregroundStyle(.secondary)
                .padding(10).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.waitingKeyRelease)
              .help(isCapturing ? "取消本次按键设置/测试，保留原绑定" : "清除当前语音热键（保存后生效）")
              .accessibilityLabel(isCapturing ? "取消按键设置或测试" : "清除语音热键")
              .accessibilityIdentifier("voiceHotkeyClear")
          }
        }.frame(width:200).background(Color(nsColor:.controlColor),in:RoundedRectangle(cornerRadius:11))
      }
      if model.recordingKeys {
        Text("请按下并松开一个按键，或最多三个按键的组合。按 Esc 或右侧 × 取消；这里只设置热键，不录音。").font(.caption).foregroundStyle(.tint)
      } else if model.waitingKeyRelease {
        Text("请完整松开刚才的按键，再设置新键。").font(.caption).foregroundStyle(.secondary)
      } else if model.testingKeys {
        Text("热键测试中：按下 \(model.downCount) 次，松开 \(model.upCount) 次。按 Esc 或右侧 × 结束；不录音、不联网。").font(.caption)
      } else {
        Text("点击右侧按键可重新设置，× 可清除；设置完成后点击下方“保存并应用”。").font(.caption).foregroundStyle(.secondary)
      }
      DisclosureGroup("支持的按键与热键检查") {
        VStack(alignment:.leading,spacing:8) {
          Text("支持左右独立 Option（⌥）、Control（⌃）、Shift（⇧）、Command（⌘）或 F13～F19，可设置单键或最多三键组合。普通文字键、空格、回车、Fn 和 Caps Lock 不支持。系统快捷键冲突仍需实际检查。").font(.caption)
          Button("只检查热键按下/松开（不录音）") { model.keyMode(record:false) }
            .disabled(isCapturing || model.waitingKeyRelease || model.draft.voice.binding == nil)
        }.padding(.top,8)
      }.font(.caption)
    }.padding(.vertical,8)
  }
}

struct SettingsView: View {
  @ObservedObject var model:HelperModel
  @State private var deleteConfirm = false
  @State private var deployConfirm = false
  @State private var migrateConfirm = false
  @State private var recoveryConfirm = false
  @State private var tab = 0
  private var profile:Binding<LetterProfile> {
    Binding(get:{ model.draft.letters[model.selectedSchema] ?? LetterProfile() },
            set:{ if !model.selectedSchema.isEmpty { model.draft.letters[model.selectedSchema] = $0 } })
  }
  private func rgb(_ value:Binding<String>) -> Binding<Color> {
    Binding(get:{
      let number = UInt32(value.wrappedValue.dropFirst(),radix:16) ?? 0
      return Color(.sRGB,red:Double((number >> 16) & 255)/255,green:Double((number >> 8) & 255)/255,blue:Double(number & 255)/255,opacity:1)
    },set:{ color in
      guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
      value.wrappedValue = String(format:"#%02X%02X%02X",Int((converted.redComponent*255).rounded()),Int((converted.greenComponent*255).rounded()),Int((converted.blueComponent*255).rounded()))
    })
  }
  var body:some View {
    VStack(alignment:.leading,spacing:12) {
      Text("增强输入设置").font(.title2)
      Text("隔离开发目录，不修改 ~/Library/Rime。两项功能独立，语音默认关闭；任何测试结论均按实际层级显示。").foregroundStyle(.secondary)
      TabView(selection:$tab) {
        ScrollView {
          Form {
            Text(model.schemaSource).font(.caption)
            Picker("方案",selection:$model.selectedSchema) { ForEach(model.schemas,id:\.self) { Text($0).tag($0) } }
            Button("刷新方案") { model.refreshSchemas() }
            if model.selectedSchema.isEmpty { Text("尚未发现源方案；刷新后选择方案再配置字母选词。").foregroundStyle(.secondary) }
            Group {
            Toggle("启用此方案字母选词",isOn:profile.enabled)
            TextField("选词字母",text:profile.keys)
            Text("从左到右依次对应当前页 1–9；默认 asdfghjkl，也可设置其他不重复小写字母。正常拼音编辑阶段仍不参与选词。").font(.caption)
            Stepper("每页 \(profile.wrappedValue.pageSize) 项",value:profile.pageSize,in:1...9)
            Toggle("拼音编辑时隐藏候选",isOn:profile.hideCandidates)
            Toggle("使用输入法默认外观",isOn:profile.useDefaultAppearance)
            Text("默认外观沿用输入法配置。关闭后，可使用下方的自定义字体、排列和配色。").font(.caption)
            Group {
            Picker("候选列表排列",selection:profile.appearance.layout) {
              Text("竖排（每行一个词）").tag(CandidateLayout.stacked)
              Text("横排（同一行）").tag(CandidateLayout.linear)
            }.pickerStyle(.segmented)
            Picker("候选字体",selection:profile.appearance.fontFace) { ForEach(model.fonts,id:\.self) { Text($0).tag($0) } }
            Stepper("候选字号：\(profile.wrappedValue.appearance.fontPoint) pt",value:profile.appearance.fontPoint,in:10...48)
            Stepper("字母标签字号：\(profile.wrappedValue.appearance.labelFontPoint) pt",value:profile.appearance.labelFontPoint,in:10...32)
            Stepper("竖排候选行距：\(profile.wrappedValue.appearance.lineSpacing) pt",value:profile.appearance.lineSpacing,in:0...24)
            HStack {
              ColorPicker("普通候选/标签",selection:rgb(profile.appearance.candidateRGB),supportsOpacity:false)
              ColorPicker("高亮候选/标签",selection:rgb(profile.appearance.highlightedRGB),supportsOpacity:false)
            }
            HStack {
              ColorPicker("候选背景",selection:rgb(profile.appearance.backgroundRGB),supportsOpacity:false)
              ColorPicker("细边框",selection:rgb(profile.appearance.borderRGB),supportsOpacity:false)
            }
            }.disabled(profile.wrappedValue.useDefaultAppearance)
            Button("恢复此方案默认外观和默认字母") {
              var value = profile.wrappedValue; value.keys = LetterProfile().keys; value.pageSize = 9; value.useDefaultAppearance = true; value.appearance = CandidateAppearance(); profile.wrappedValue = value
            }
            Text("新方案默认使用输入法外观。自定义外观和选词字母从下一次输入生效，无需重新部署；页大小和处理器仍需部署。").font(.caption)
            Text("首次空格仅进入选词；第二次空格确认高亮。字母/数字对应当前页，Esc 保留拼音，退格交回原方案一次。修改 processors/页大小需要保存后确认部署。")
            HStack {
              Button("确认应用并重新部署…") { deployConfirm = true }
              Button("真实隔离 Rime 测试") { model.deployLetters(test:true) }
              Button("取消字母自测") { model.stopAll(cancel:true) }
            }
            Text("自测使用独立原生进程和固定测试词库：首次空格、字母、第二页、取消、退格等 14 项。仅只读核对选中方案的处理器/页大小，不在个人词库中模拟选择或学习；不能当作当前方案完全兼容、实际鼠标或 GUI 渲染验收。").font(.caption)
            Button("迁移已有 space_select_gate 并部署…") { migrateConfirm = true }
              .disabled(!profile.wrappedValue.enabled)
            Text("普通应用不会悄悄替换旧 gate。显式迁移仅替换已识别处理器，保留实际其余顺序与原补丁恢复记录。block patch 内原有完整处理器列表、行内 flow 列表和页大小可迁移；根 flow/merge/受影响嵌套键会拒绝而非重写。").font(.caption)
            }.disabled(model.selectedSchema.isEmpty)
          }.formStyle(.grouped).padding()
        }.tabItem { Text("字母选词") }.tag(0)
        ScrollView {
          Form {
            Toggle("启用语音输入",isOn:$model.draft.voice.enabled)
            VoiceInputModeSettings(model:model)
            Text(model.draft.voice.model.isDoubao ? "推理提供方：火山引擎豆包语音" : "推理提供方：阿里云百炼")
            Picker("识别模型",selection:$model.draft.voice.model) {
              ForEach(VoiceModel.allCases,id:\.self) { value in
                Text(value.title).tag(value)
              }
            }.accessibilityIdentifier("voiceModelPicker")
            if model.draft.voice.model.supportsNativePolish {
              Toggle("原生润色",isOn:Binding(get:{model.draft.voice.model.isDoubao ? model.draft.voice.doubao.nativePolish : model.draft.voice.nativePolish},set:{value in
                if model.draft.voice.model.isDoubao { model.draft.voice.doubao.nativePolish=value }
                else { model.draft.voice.nativePolish=value }
              })).accessibilityIdentifier("voiceNativePolish")
              Text(model.draft.voice.model.isDoubao ? "豆包语义顺滑：过滤语气词、重复和不流畅表达；默认关闭，由识别模型直接处理。" : "开启后由识别模型过滤语气词并润色文字，可能调整表达；默认关闭。").font(.caption).foregroundStyle(.secondary)
            }
            Text("模型与润色修改保存后从下一次语音输入生效；下方测试框使用当前表单选择。麦克风、热键和浮窗设置共用。").font(.caption).foregroundStyle(.secondary)
            if model.draft.voice.model.isDoubao {
              Picker("豆包模型资源",selection:$model.draft.voice.doubao.resource) {
                ForEach(DoubaoResource.allCases,id:\.self) { value in Text(value.title).tag(value) }
              }.accessibilityIdentifier("doubaoResourcePicker")
              Text("请选与火山引擎账户已开通的版本及计费类型一致的资源。").font(.caption).foregroundStyle(.secondary)
              Picker("豆包鉴权方式",selection:$model.draft.voice.doubao.authentication) {
                Text("新版 API Key").tag(DoubaoAuthentication.apiKey)
                Text("旧版 App ID + Access Token").tag(DoubaoAuthentication.appAccessToken)
              }.accessibilityIdentifier("doubaoAuthenticationPicker")
              if model.draft.voice.doubao.authentication == .appAccessToken {
                TextField("豆包 App ID",text:$model.draft.voice.doubao.appID)
                  .accessibilityIdentifier("doubaoAppID")
              }
              if model.showKey { TextField("豆包新密钥（空白保留原密钥）",text:$model.newDoubaoKey) }
              else { SecureField("豆包新密钥（空白保留原密钥）",text:$model.newDoubaoKey) }
              Text("新版填写火山引擎 API Key，旧版填写 Access Token。豆包凭据单独保存，不会使用或覆盖千问的 Key。").font(.caption).foregroundStyle(.secondary)
            } else {
              Text("两个千问模型共用下面的 API Key、地域和工作空间。").font(.caption).foregroundStyle(.secondary)
              Picker("地域",selection:$model.draft.voice.region) {
                Text("请选择账户地域").tag(Region?.none)
                Text("北京").tag(Region?.some(.beijing)); Text("新加坡").tag(Region?.some(.singapore))
              }
              TextField("Workspace ID",text:$model.draft.voice.workspace)
              if model.credentialDestinationChanged {
                Text("地域/工作空间已改变，将自动校验 Key 是否能连接当前服务。空白 Key 保存会保留原凭据。").font(.caption).foregroundStyle(.orange)
              }
              if model.showKey { TextField("新 Key（空白保留旧 Key）",text:$model.newKey) }
              else { SecureField("新 Key（空白保留旧 Key）",text:$model.newKey) }
            }
            Text((try? model.draft.voice.endpoint().absoluteString) ?? "请填写所选服务的有效配置。").font(.caption).textSelection(.enabled)
            HStack {
              Toggle("显示新输入",isOn:$model.showKey)
              Text(model.draft.voice.activeCredentialReference == nil ? "所选服务未保存密钥" : "所选服务密钥已保存至 Keychain，不回显")
              Button("删除所选服务密钥…") { deleteConfirm = true }
            }
            Picker("麦克风",selection:Binding(get:{model.draft.voice.deviceUID ?? ""},set:{model.draft.voice.deviceUID = $0.isEmpty ? nil : $0})) {
              Text("系统默认设备").tag("")
              ForEach(model.devices) { Text($0.name).tag($0.id) }
            }
            Text(model.productionMicrophoneStatus).font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("productionMicrophoneStatus")
            HStack {
              Button("重新校验 API Key 与连接") { model.testConnection() }.disabled(model.checkingConnection)
              Button("刷新设备") { model.refreshDevices() }
            }
            HStack {
              if model.checkingConnection { ProgressView().controlSize(.small) }
              Text(model.connectionStatus).font(.caption).accessibilityIdentifier("voiceConnectionStatus")
            }
            Text("填写完整后自动校验，不采音、不发送识别任务。实际语音输入需按住热键。").font(.caption).foregroundStyle(.secondary)
            Section("麦克风权限") {
              Label(model.microphoneStatus,systemImage:model.microphoneAuthorization == .authorized ? "checkmark.circle.fill" : "mic.badge.plus")
                .foregroundStyle(model.microphoneAuthorization == .authorized ? Color.green : Color.secondary)
                .accessibilityIdentifier("microphonePermissionStatus")
              HStack {
                if model.microphoneAuthorization == .notDetermined {
                  Button(model.requestingMicrophone ? "等待系统授权…" : "申请麦克风权限") { model.requestMicrophone() }
                    .disabled(model.requestingMicrophone).accessibilityIdentifier("microphonePermissionRequest")
                }
                Button("打开系统麦克风设置") { model.openMicrophoneSettings() }
                  .accessibilityIdentifier("microphoneSystemSettings")
                Button("刷新状态") { model.refreshMicrophoneAuthorization() }
                  .disabled(model.requestingMicrophone)
              }
              Text("首次申请后，系统会记录此应用的麦克风权限。系统列表可能显示“鼠须管增强开发版”或“鼠须管增强设置开发版”；已拒绝时需在系统设置中开启。申请权限不会开始录音。").font(.caption).foregroundStyle(.secondary)
            }
              Text(model.focusPermissionStatus).font(.caption).accessibilityIdentifier("focusPermissionStatus")
              HStack {
                Button("授权输入法焦点检测") { model.requestFocusPermission() }
                Button("刷新焦点权限") { model.refreshFocusPermission() }
              }
              Text(model.inputMethodConnected ? "输入法已连接" : "输入法尚未连接；请从增强输入法菜单打开设置。").font(.caption)
            Stepper("录音上限：\(model.draft.voice.maximumSeconds) 秒",value:$model.draft.voice.maximumSeconds,in:10...300)
            Stepper("连接超时：\(model.draft.voice.connectSeconds) 秒",value:$model.draft.voice.connectSeconds,in:1...60)
            Stepper("任务启动超时：\(model.draft.voice.taskStartSeconds) 秒",value:$model.draft.voice.taskStartSeconds,in:1...60)
            Stepper("松键后最终结果超时：\(model.draft.voice.finalizeSeconds) 秒",value:$model.draft.voice.finalizeSeconds,in:1...60)
            Toggle("显示生产语音实时预览浮窗",isOn:$model.draft.voice.showPreview)
            HStack {
              Text("浮窗透明度")
              Slider(value:$model.draft.voice.previewTransparency,in:0...0.7,step:0.05)
                .accessibilityLabel("浮窗透明度")
                .accessibilityIdentifier("voicePreviewTransparency")
              Text("\(Int(model.draft.voice.previewTransparency*100))%")
                .monospacedDigit().frame(width:42,alignment:.trailing)
            }
            Toggle("显示在当前输入位置",isOn:$model.draft.voice.previewAtCaret)
              .accessibilityIdentifier("voicePreviewAtCaret")
            Text("勾选后显示在光标附近；未勾选时显示在当前屏幕下方中央、程序坞上方。透明度 0% 为不透明。保存后从下一次语音输入生效；应用未提供光标位置时使用默认位置。").font(.caption).foregroundStyle(.secondary)
            Text("松开热键后，完整文字会自动输入当前目标，浮窗随即关闭。此选项仅控制实时预览；目标改变或识别失败时仍显示可恢复的草稿。").font(.caption)
            Section("语音输入测试") {
              Text("点击下面的文本框，按住 \(model.draft.voice.binding?.label ?? "已配置的语音热键") 说话，松开后整段输入。实时识别同时显示在正常语音浮窗中；可在框内打字、选中文字或调整光标。").font(.caption)
              Text("测试会真实采音并向当前选择的语音服务上传音频，可能计费。使用当前表单配置；语音总开关可保持关闭。测试内容仅在此窗口内存中，关闭应用后丢弃。").font(.caption).foregroundStyle(.secondary)
              VoiceTestEditor(model:model).frame(height:140)
              Text(model.voiceTestHint).font(.caption).accessibilityIdentifier("voiceTestHint")
              Text("先设置所选服务的密钥、服务信息和语音热键，并主动授权麦克风。未就绪时不会开麦；Esc、切页、切窗或离开测试框会取消测试。").font(.caption)
            }
            ProgressView(value:model.level)
            HStack {
              Button("麦克风自检（2 秒，仅本地）") { model.testMicrophoneForTwoSeconds() }
              Text("已接收 \(model.localPCMSamples) 个音频采样点").font(.caption).accessibilityIdentifier("localPCMSampleCount")
            }
            HStack {
              HoldButton(title:"按住测试麦克风（仅本地）") { model.testHold(cloud:false,action:$0) }
              HoldButton(title:"按住云识别（仅预览）") { model.testHold(cloud:true,action:$0) }
            }
            Text("测试按钮也可用 Tab 聚焦后按住空格；松开停止，Esc 取消。只是设置页测试，不改变生产语音绑定；辅助技术的单次点击不是按住录音。").font(.caption)
            Text("下方按钮仅预览识别草稿；要体验正常输入，请聚焦上面的测试框并按住配置的语音热键。未保存修改不改变生产设置。")
            Text(model.preview).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            if !model.preview.isEmpty { Text(model.previewIsComplete ? "已收到整次任务的完整最终文字；仅在本窗口展示。" : "临时或可能不完整的草稿；不是完整任务确认。").font(.caption) }
            HStack {
              Button("主动复制草稿") {
                guard model.canCopyTestDraft else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.preview,forType:.string)
              }.disabled(!model.canCopyTestDraft)
              Button("丢弃测试草稿") { model.discardTestDraft() }.disabled(model.preview.isEmpty)
            }
            Text("丢弃草稿只清除文字并抑制本次迟到文本，不结束仍按住的测试；松开或 Esc 才停止/取消。新测试会替换上一条草稿，不保存历史。").font(.caption)
          }.formStyle(.grouped).padding()
        }.tabItem { Text("语音输入设置") }.tag(1)
        ScrollView { DiagnosticSettingsView(model:model) }.tabItem { Text("诊断与隐私") }.tag(2)
      }
      ScrollView { Text(model.status).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(minHeight:36,maxHeight:110)
      Text(model.applicationState).font(.caption).foregroundStyle(.secondary)
      if model.needsRecovery {
        Button("备份损坏文件并恢复已知有效配置…") { recoveryConfirm = true }.disabled(!model.recoveryAvailable)
        Text("当前为只读安全回退；语音关闭。无有效备份时不覆盖原文件，请保留现场后从备份恢复。").font(.caption)
      }
      HStack {
        Button("本地校验（不采音/联网）") { model.validate() }
        Button("保存并应用") { model.save() }.keyboardShortcut("s",modifiers:.command)
        Button("取消修改") { model.revert() }
        Button("恢复非秘密默认值") { model.defaults() }
      }
    }.padding(18)
      .onChange(of:tab) { _ in model.stopAll(cancel:true) }
      .onChange(of:model.draft.voice.enabled) { enabled in if !enabled { model.stopAll(cancel:true) } }
      .alert("删除所选服务的密钥？",isPresented:$deleteConfirm) {
        Button("取消",role:.cancel) {}
        Button("删除",role:.destructive) { model.deleteKey() }
      } message:{ Text("仅删除当前所选服务的 Keychain 项；正在使用该服务时会关闭语音。另一服务凭据和词库保留。") }
      .alert("语音服务设置错误",isPresented:Binding(get:{model.connectionError != nil},set:{if !$0 { model.connectionError=nil }})) {
        Button("确定",role:.cancel) { model.connectionError=nil }
      } message:{ Text(model.connectionError ?? "请检查语音服务设置。") }
      .alert("显式恢复最后有效配置？",isPresented:$recoveryConfirm) {
        Button("取消",role:.cancel) {}
        Button("备份并恢复") { model.restoreKnownValid() }
      } message:{ Text("损坏文件先另存，不删除词库和 Keychain。恢复后语音保持关闭，尚未保存的表单修改不应用。") }
      .alert("应用字母补丁并重新部署？",isPresented:$deployConfirm) {
        Button("取消",role:.cancel) {}
        Button("确认") { model.deployLetters(test:false) }
      } message:{ Text("先保存设置。仅在无组合、无语音任务时执行；修改前自动备份，失败不会报告成功。") }
      .alert("显式迁移现有空格 gate？",isPresented:$migrateConfirm) {
        Button("取消",role:.cancel) {}
        Button("迁移并部署") { model.deployLetters(test:false,replaceLegacy:true) }
      } message:{ Text("先保存并启用此方案。只处理已识别 space_select_gate，不改方案或词库；依据实际已部署处理器保留其他顺序，源补丁和原字段记录可恢复。迁移形成处理器快照；上游处理器结构变化后应先关闭部署，再重新启用。复杂结构或所有权冲突会拒绝。") }
  }
}
