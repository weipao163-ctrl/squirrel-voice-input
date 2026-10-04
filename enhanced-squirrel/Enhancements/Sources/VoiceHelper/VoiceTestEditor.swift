import AppKit
import SwiftUI
import EnhancementCore

// A real native text editor. Only this view's focused local hotkey monitor can
// start its test; no global keyboard monitor, synthetic paste, or external IMK
// target is involved.
struct VoiceTestEditor:NSViewRepresentable {
  @ObservedObject var model:HelperModel
  func makeNSView(context:Context) -> NSScrollView {
    let editor=TestTextView(frame:NSRect(x:0,y:0,width:500,height:130))
    editor.model=model; editor.delegate=editor
    editor.isRichText=false; editor.allowsUndo=true; editor.isAutomaticQuoteSubstitutionEnabled=false
    editor.isAutomaticDashSubstitutionEnabled=false
    editor.font=NSFont.systemFont(ofSize:15); editor.textContainerInset=NSSize(width:10,height:8)
    editor.isHorizontallyResizable=false; editor.isVerticallyResizable=true
    editor.autoresizingMask=[.width]; editor.textContainer?.widthTracksTextView=true
    editor.minSize=NSSize(width:0,height:130); editor.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
    editor.setAccessibilityLabel("语音输入测试框")
    editor.setAccessibilityHelp("可直接编辑文字。聚焦此框后按住配置的语音热键说话，松开后完整结果插入当前光标处。会上传音频并可能计费。")
    editor.string=model.voiceTestText
    let scroll=NSScrollView(); scroll.documentView=editor; scroll.hasVerticalScroller=true; scroll.borderType = .bezelBorder
    model.testEditorController.attach(editor)
    return scroll
  }
  func updateNSView(_ view:NSScrollView,context:Context) {}
  static func dismantleNSView(_ view:NSScrollView,coordinator:()) {
    guard let editor=view.documentView as? TestTextView else { return }
    editor.model?.testEditorController.detach(editor)
  }
  final class TestTextView:NSTextView,NSTextViewDelegate {
    weak var model:HelperModel?
    override func becomeFirstResponder() -> Bool {
      let accepted=super.becomeFirstResponder()
      if accepted { model?.testEditorController.focus(self) }; return accepted
    }
    override func resignFirstResponder() -> Bool {
      let accepted=super.resignFirstResponder()
      if accepted { model?.testEditorController.blur() }; return accepted
    }
    func textDidChange(_ notification:Notification) {
      model?.voiceTestText=string; model?.testEditorChanged()
    }
    func textViewDidChangeSelection(_ notification:Notification) { model?.testEditorChanged() }
  }
}

final class VoiceTestEditorController {
  weak var editor:VoiceTestEditor.TestTextView?
  private weak var model:HelperModel?
  private var keys=PhysicalKeys()
  private var pressID:UUID?
  private var monitor:Any?
  private var focused=false
  private var consumed:Set<UInt16>=[]
  init(model:HelperModel) { self.model=model }
  deinit { removeMonitor() }
  func attach(_ editor:VoiceTestEditor.TestTextView) { self.editor=editor }
  func detach(_ editor:VoiceTestEditor.TestTextView) {
    guard self.editor === editor else { return }; blur(); self.editor=nil
  }
  var isFocused:Bool { focused && editor?.isHiddenOrHasHiddenAncestor == false && editor?.window?.isKeyWindow == true && editor?.window?.firstResponder === editor }
  func focus(_ editor:VoiceTestEditor.TestTextView) {
    self.editor=editor; focused=true
    let pressed=Set((0..<128).compactMap { CGEventSource.keyState(.combinedSessionState,key:CGKeyCode($0)) ? UInt16($0) : nil })
    if pressed.isEmpty { keys.verifiedAllReleased(); consumed=[] }
    keys.reconcileAfterActivation(pressed:pressed)
    installMonitor()
  }
  func blur() {
    focused=false; model?.invalidateTestEditorTarget()
    stopOwned(cancel:true)
    if model?.hasEditorVoiceSession == true { model?.stopAll(cancel:true) }
    settleMonitor()
  }
  func stopOwned(cancel:Bool) {
    let id=pressID; pressID=nil; keys.cancel()
    if let id { model?.testHold(cloud:true,action:cancel ? .cancel(id) : .release(id)) }
  }
  // Called on page/window changes, sleeping, cancellation or configuration modes.
  func cancelLifecycle() { focused=false; pressID=nil; keys.cancel(); settleMonitor() }
  func restoreFocusIfNeeded() {
    if let editor, !editor.isHiddenOrHasHiddenAncestor, editor.window?.isKeyWindow == true, editor.window?.firstResponder === editor { focus(editor) }
  }
  func anchor() -> NSRect? {
    guard let editor, editor.window != nil else { return nil }
    let range=editor.selectedRange()
    var actual=NSRange(location:NSNotFound,length:0)
    let caret=editor.firstRect(forCharacterRange:range,actualRange:&actual)
    if [caret.minX,caret.minY,caret.width,caret.height].allSatisfy({$0.isFinite}),caret.height > 0 {
      return caret
    }
    return nil
  }
  private func installMonitor() {
    guard monitor == nil else { return }
    monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp,.flagsChanged,.leftMouseDown]) { [weak self] event in
      guard let self, let model=self.model else { return event }
      if (model.recordingKeys || model.testingKeys) && self.consumed.isEmpty { return event }
      if event.type == .leftMouseDown {
        if self.pressID != nil { model.testEditorChanged() }
        return event
      }
      let down=event.type == .flagsChanged
        ? CGEventSource.keyState(.combinedSessionState,key:CGKeyCode(event.keyCode)) : event.type == .keyDown
      let repeated=event.type == .keyDown && event.isARepeat
      let previouslyConsumed=self.consumed.contains(event.keyCode)
      if event.type == .keyDown && event.keyCode == 53 && (self.pressID != nil || model.hasEditorVoiceSession) {
        model.invalidateTestEditorTarget(); self.stopOwned(cancel:true)
        model.stopAll(cancel:true); return nil
      }
      let binding=model.draft.voice.binding
      let ready=self.isFocused && model.editorVoiceReadiness == nil
      let action=self.keys.event(code:event.keyCode,down:down,repeated:repeated,binding:binding,canStart:ready)
      if action == .start {
        let id=UUID(); self.pressID=id; self.consumed=self.keys.ownsRelease
        model.testHold(cloud:true,action:.start(id),intoTestEditor:true)
      } else if action == .stop {
        let id=self.pressID; self.pressID=nil
        if let id { model.testHold(cloud:true,action:.release(id)) }
      } else if down && !repeated && self.isFocused, let binding,
                self.keys.held == binding.codes, let reason=model.editorVoiceReadiness {
        model.status=reason
      }
      if down && self.isFocused && action != .start && !self.consumed.contains(event.keyCode), model.hasEditorVoiceSession {
        model.testEditorChanged() // Ordinary editing keeps its original input path.
      }
      if self.keys.held.isDisjoint(with:self.consumed) { self.consumed=[] }
      let consume=previouslyConsumed || self.consumed.contains(event.keyCode)
      self.settleMonitor(); return consume ? nil : event
    }
  }
  private func settleMonitor() {
    if !focused && consumed.isEmpty { removeMonitor() }
  }
  private func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor=nil } }
}
