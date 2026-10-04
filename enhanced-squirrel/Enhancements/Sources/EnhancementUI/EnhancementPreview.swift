import AppKit
import EnhancementIPC
import EnhancementCore

// A floating panel must never become the input target, including during resize.
private final class VoicePreviewPanel:NSPanel {
  override var canBecomeKey:Bool { false }
  override var canBecomeMain:Bool { false }
}

private final class VoiceLevelView:NSView {
  var level=0.0 { didSet { needsDisplay=true; setAccessibilityValue("\(Int(level*100))%") } }
  override init(frame:NSRect) {
    super.init(frame:frame); setAccessibilityElement(true)
    setAccessibilityRole(.levelIndicator); setAccessibilityLabel("麦克风音量")
  }
  required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect:NSRect) {
    for i in 0..<5 {
      let height:CGFloat=CGFloat([4,8,12,8,4][i])
      let active=level > Double(i)/5
      (active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
      NSBezierPath(roundedRect:NSRect(x:CGFloat(i)*5,y:(bounds.height-height)/2,width:3,height:height),xRadius:1.5,yRadius:1.5).fill()
    }
  }
}

public final class EnhancementPreview {
  public static let shared = EnhancementPreview()
  private let panel = VoicePreviewPanel(contentRect:NSRect(x:0,y:0,width:340,height:112),
                              styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  private let symbol=NSImageView()
  private let state=NSTextField(labelWithString:"")
  private let elapsed=NSTextField(labelWithString:"")
  private let meter=VoiceLevelView(frame:.zero)
  private let text=NSTextView(frame:NSRect(x:0,y:0,width:308,height:40))
  private let scroll=NSScrollView()
  private let detail=NSTextField(wrappingLabelWithString:"")
  private let footer=NSStackView()
  private let stack=NSStackView()
  private var textHeight:NSLayoutConstraint!
  private var anchor:NSRect?
  private var atCaret=false
  private var drafts=VoiceDraftStore()
  private var replacementNotice=false
  private var dismissTimer:Timer?
  private let dismissInterval:TimeInterval
  private lazy var copy=NSButton(title:"复制草稿",target:self,action:#selector(copyDraft))
  private lazy var discard=NSButton(title:"丢弃",target:self,action:#selector(discardDraft))

  public init(title:String = "语音输入 · 实时预览",dismissInterval:TimeInterval = 4) {
    self.dismissInterval=max(0.01,dismissInterval)
    panel.title=title; panel.setAccessibilityLabel(title); panel.level = .floating
    panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true
    panel.hidesOnDeactivate=false; panel.isMovableByWindowBackground=true
    panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
    let material=NSVisualEffectView(frame:panel.contentView!.bounds)
    material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
    material.wantsLayer=true; material.layer?.cornerRadius=16; material.layer?.masksToBounds=true
    panel.contentView=material
    state.font=NSFont.systemFont(ofSize:12,weight:.semibold)
    state.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    state.setAccessibilityIdentifier("voicePreviewState")
    elapsed.font=NSFont.monospacedDigitSystemFont(ofSize:11,weight:.regular)
    elapsed.textColor = .secondaryLabelColor
    symbol.image=NSImage(systemSymbolName:"waveform",accessibilityDescription:nil)
    symbol.contentTintColor = .controlAccentColor
    symbol.setAccessibilityElement(false)
    let space=NSView()
    let header=NSStackView(views:[symbol,state,space,meter,elapsed])
    header.orientation = .horizontal; header.alignment = .centerY; header.spacing=8
    text.isEditable=false; text.isSelectable=true; text.drawsBackground=false
    text.font=NSFont.systemFont(ofSize:14); text.isHorizontallyResizable=false; text.isVerticallyResizable=true
    text.textContainer?.widthTracksTextView=true; text.textContainer?.lineFragmentPadding=0
    text.textContainerInset=NSSize(width:0,height:2); text.autoresizingMask=[.width]
    text.setAccessibilityIdentifier("voicePreviewTranscript")
    scroll.hasVerticalScroller=true; scroll.autohidesScrollers=true; scroll.documentView=text
    scroll.drawsBackground=false; scroll.borderType = .noBorder
    detail.font=NSFont.systemFont(ofSize:11); detail.textColor = .secondaryLabelColor
    detail.maximumNumberOfLines=3; detail.lineBreakMode = .byTruncatingTail
    for button in [copy,discard] {
      button.bezelStyle = .inline; button.controlSize = .small
      button.font=NSFont.systemFont(ofSize:11,weight:.medium)
    }
    copy.setAccessibilityIdentifier("voicePreviewCopy")
    discard.setAccessibilityIdentifier("voicePreviewDiscard")
    copy.contentTintColor = .controlAccentColor
    discard.contentTintColor = .labelColor
    copy.attributedTitle=NSAttributedString(string:"复制草稿",attributes:[.font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.controlAccentColor])
    discard.attributedTitle=NSAttributedString(string:"丢弃",attributes:[.font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.secondaryLabelColor])
    footer.orientation = .horizontal; footer.spacing=10
    footer.addArrangedSubview(copy); footer.addArrangedSubview(discard)
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=10
    [header,scroll,detail,footer].forEach { stack.addArrangedSubview($0) }
    stack.translatesAutoresizingMaskIntoConstraints=false; material.addSubview(stack)
    textHeight=scroll.heightAnchor.constraint(equalToConstant:36)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo:material.leadingAnchor,constant:16),
      stack.trailingAnchor.constraint(equalTo:material.trailingAnchor,constant:-16),
      stack.topAnchor.constraint(equalTo:material.topAnchor,constant:14),
      stack.bottomAnchor.constraint(equalTo:material.bottomAnchor,constant:-14),
      header.widthAnchor.constraint(equalTo:stack.widthAnchor), header.heightAnchor.constraint(equalToConstant:18),
      symbol.widthAnchor.constraint(equalToConstant:16),symbol.heightAnchor.constraint(equalToConstant:16),
      meter.widthAnchor.constraint(equalToConstant:23),meter.heightAnchor.constraint(equalToConstant:16),
      scroll.widthAnchor.constraint(equalTo:stack.widthAnchor),textHeight,
      detail.widthAnchor.constraint(equalTo:stack.widthAnchor)])
    copy.isEnabled=false; discard.isEnabled=false; footer.isHidden=true; detail.isHidden=true
  }
  public func configure(transparency:Double,atCaret:Bool) {
    let safe=transparency.isFinite ? min(0.7,max(0,transparency)) : 0.1
    panel.alphaValue=CGFloat(1-safe); self.atCaret=atCaret
    if panel.isVisible { position() }
  }
  public func begin(_ identity:VoiceIdentity,showPreview:Bool,transparency:Double = 0.1,
                    atCaret:Bool = false,anchor:NSRect? = nil) {
    dismissTimer?.invalidate(); dismissTimer=nil
    replacementNotice=drafts.begin(identity)
    self.anchor=anchor; configure(transparency:transparency,atCaret:atCaret)
    copy.isEnabled=false; discard.isEnabled=false; footer.isHidden=true
    setHeader("正在连接",symbol:"mic",duration:0,level:0)
    setText("按住说话，松开后输入",placeholder:true)
    setDetail(replacementNotice ? "本次录音将替换上一条未复制草稿，不保存历史。" : "")
    resize()
    // Warn before sending begin without a modal dialog or delaying key-up.
    if showPreview || replacementNotice { position(); panel.orderFrontRegardless() }
    else { panel.orderOut(nil) }
  }
  public func update(_ value:VoiceUpdate) {
    guard drafts.accept(value.identity,phase:value.phase,text:value.text,complete:value.complete) else { return }
    dismissTimer?.invalidate(); dismissTimer=nil
    if value.phase == .cancelled { clear(); return }
    let title:String, icon:String
    switch value.phase {
    case .preparing: title="正在连接"; icon="mic"
    case .recording: title="正在聆听"; icon="waveform"
    case .finalizing: title="正在整理文字"; icon="ellipsis"
    case .ready: title="识别已完成"; icon="checkmark.circle"
    case .review: title="已保留草稿"; icon="doc.text"
    case .failed: title="识别未完成"; icon="exclamationmark.circle"
    case .cancelled: return
    }
    setHeader(title,symbol:icon,duration:value.duration,level:value.phase == .recording ? value.level : 0)
    meter.isHidden=value.phase != .recording
    let emptyText=value.phase == .finalizing ? "录音已停止，正在等待最终结果…" : "按住说话，松开后输入"
    setText(drafts.text.isEmpty ? emptyText : drafts.text,placeholder:drafts.text.isEmpty)
    copy.isEnabled=drafts.canCopy; discard.isEnabled=drafts.canCopy
    footer.isHidden = !drafts.canCopy
    var explanation=""
    if [.ready,.review,.failed].contains(value.phase) {
      explanation=drafts.text.isEmpty ? "尚无可恢复文字" : (drafts.complete ? "完整结果 · 未自动输入的草稿" : "临时草稿 · 可能不完整")
      if !value.message.isEmpty { explanation += "\n"+value.message }
    } else if replacementNotice { explanation="上一条草稿已被本次录音替换，不保存历史。" }
    setDetail(explanation); resize()
    if !value.showPreview && ![.review,.failed].contains(value.phase) {
      panel.orderOut(nil); return // Recovery remains accessible when live preview is off.
    }
    position(); panel.orderFrontRegardless()
    if [.ready,.review,.failed].contains(value.phase) { scheduleDismiss() }
  }
  private func setHeader(_ title:String,symbol icon:String,duration:Double,level:Double) {
    state.stringValue=title
    symbol.image=NSImage(systemSymbolName:icon,accessibilityDescription:nil)
    symbol.contentTintColor=icon == "exclamationmark.circle" ? .systemOrange : .controlAccentColor
    let seconds=duration.isFinite ? max(0,min(duration,3600)) : 0
    elapsed.stringValue=String(format:"%02d:%02d",Int(seconds)/60,Int(seconds)%60)
    meter.level=level.isFinite ? max(0,min(level,1)) : 0
    meter.isHidden=true
  }
  private func setText(_ value:String,placeholder:Bool) {
    // Replace partials, never concatenate provider repetitions or grow history.
    let paragraph=NSMutableParagraphStyle(); paragraph.lineSpacing=3
    text.textStorage?.setAttributedString(NSAttributedString(string:value,attributes:[
      .font:NSFont.systemFont(ofSize:14),.foregroundColor:placeholder ? NSColor.secondaryLabelColor : NSColor.labelColor,
      .paragraphStyle:paragraph]))
    text.toolTip=nil
  }
  private func setDetail(_ value:String) {
    detail.stringValue=value; detail.toolTip=value.isEmpty ? nil : value
    detail.isHidden=value.isEmpty
  }
  private func resize() {
    text.textContainer?.containerSize=NSSize(width:308,height:CGFloat.greatestFiniteMagnitude)
    if let container=text.textContainer { text.layoutManager?.ensureLayout(for:container) }
    let measured=text.textContainer.flatMap { text.layoutManager?.usedRect(for:$0).height } ?? 32
    textHeight.constant=min(98,max(32,ceil(measured)+4))
    // The scroll view caps long transcripts; the window stays within 340 x 238.
    let detailHeight:CGFloat=detail.isHidden ? 0 : min(42,max(15,detail.sizeThatFits(NSSize(width:308,height:42)).height))
    let height=28+18+10+textHeight.constant+(detail.isHidden ? 0 : 10+detailHeight)+(footer.isHidden ? 0 : 10+20)
    let top=panel.frame.maxY
    panel.setFrame(NSRect(x:panel.frame.minX,y:top-height,width:340,height:height),display:true)
    panel.contentView?.layoutSubtreeIfNeeded()
  }
  public func position(near anchor:NSRect?) { self.anchor=anchor; position() }
  public static func placement(size:NSSize,screen:NSRect,visible:NSRect,caret:NSRect?) -> NSRect {
    let width=min(size.width,visible.width),height=min(size.height,visible.height)
    let x:CGFloat,y:CGFloat
    if let caret {
      x=caret.minX
      let below=caret.minY-height-8
      y=below >= visible.minY ? below : caret.maxY+8
    } else {
      x=visible.midX-width/2
      // Visible frame excludes a visible Dock. Reserve bottom room as well
      // when it auto-hides, keeping the default away from the top-right corner.
      y=max(visible.minY+20,screen.minY+100)
    }
    return NSRect(x:min(max(x,visible.minX),visible.maxX-width),
      y:min(max(y,visible.minY),visible.maxY-height),width:width,height:height)
  }
  private func position() {
    let validAnchor=anchor.flatMap { r -> NSRect? in
      [r.minX,r.minY,r.width,r.height].allSatisfy({$0.isFinite}) && r.width >= 0 && r.height > 0 ? r : nil
    }
    let anchorScreen=validAnchor.flatMap { r in NSScreen.screens.first {
      $0.frame.intersects(r.insetBy(dx:-1,dy:-1))
    } }
    guard let screen=anchorScreen ?? NSScreen.screens.first(where:{NSMouseInRect(NSEvent.mouseLocation,$0.frame,false)}) ?? NSScreen.main else { return }
    let frame=Self.placement(size:panel.frame.size,screen:screen.frame,visible:screen.visibleFrame,
      caret:atCaret && anchorScreen != nil ? validAnchor : nil)
    panel.setFrameOrigin(frame.origin)
  }
  public func clear() {
    dismissTimer?.invalidate(); dismissTimer=nil
    drafts.clear(); text.string=""; state.stringValue=""; setDetail("")
    copy.isEnabled=false; discard.isEnabled=false; footer.isHidden=true
    replacementNotice=false; anchor=nil; panel.orderOut(nil)
  }
  public var hasRecoverableDraft:Bool { drafts.canCopy }
  // Automatic dismissal hides the panel, not its terminal draft. The input
  // method menu can restore it without inserting text or stealing focus.
  public func showDraft() {
    guard drafts.canCopy else { return }
    dismissTimer?.invalidate(); dismissTimer=nil
    setHeader("已保留草稿",symbol:"doc.text",duration:0,level:0)
    setText(drafts.text,placeholder:false)
    setDetail(drafts.complete ? "完整结果 · 未自动输入的草稿" : "临时草稿 · 可能不完整")
    copy.isEnabled=true; discard.isEnabled=true; footer.isHidden=false
    resize(); position(); panel.orderFrontRegardless()
  }
  public func notice(_ message:String) {
    dismissTimer?.invalidate(); dismissTimer=nil
    setHeader("语音输入",symbol:"info.circle",duration:0,level:0)
    if drafts.text.isEmpty { setText(message,placeholder:true); setDetail("") }
    else { setDetail(message) }
    resize(); position(); panel.orderFrontRegardless()
    scheduleDismiss()
  }
  private func scheduleDismiss() {
    dismissTimer=Timer.scheduledTimer(withTimeInterval:dismissInterval,repeats:false) { [weak self] _ in
      self?.panel.orderOut(nil); self?.dismissTimer=nil
    }
  }
  @objc private func copyDraft() {
    guard drafts.canCopy else { return }
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(drafts.text,forType:.string)
  }
  @objc private func discardDraft() {
    drafts.discard(); text.string=""; copy.isEnabled=false; discard.isEnabled=false
    footer.isHidden=true; panel.orderOut(nil)
  }
}
