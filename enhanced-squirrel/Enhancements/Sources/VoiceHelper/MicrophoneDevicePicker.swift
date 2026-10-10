import AppKit
import SwiftUI

// A disconnected UID remains an explicit selection, never an absent SwiftUI
// Picker tag or an implicit switch to another microphone.
final class MicrophonePopUpButton:NSPopUpButton {
  var selectionChanged:((String?)->Void)?

  override init(frame:NSRect,pullsDown:Bool) {
    super.init(frame:frame,pullsDown:pullsDown)
    target=self; action=#selector(changed(_:))
    setAccessibilityLabel("麦克风")
    setAccessibilityIdentifier("voiceMicrophonePicker")
  }
  required init?(coder:NSCoder) { nil }

  func update(devices:[InputDevice],selectedUID:String?) {
    removeAllItems()
    menu?.autoenablesItems=false
    func append(_ title:String,_ uid:String?,enabled:Bool=true) {
      let item=NSMenuItem(title:title,action:nil,keyEquivalent:"")
      item.representedObject=uid; item.isEnabled=enabled
      menu?.addItem(item)
    }
    append("系统默认设备",nil)
    if let uid=selectedUID,!devices.contains(where:{$0.id == uid}) {
      append("已选麦克风不可用 · 请选择其他设备",uid,enabled:false)
    }
    for device in devices {
      append(device.name,device.id)
    }
    let selected=itemArray.first { ($0.representedObject as? String) == selectedUID }
    select(selected)
  }
  @objc private func changed(_ sender:Any?) {
    selectionChanged?(selectedItem?.representedObject as? String)
  }
}

struct MicrophoneDevicePicker:NSViewRepresentable {
  @Binding var selection:String?
  var devices:[InputDevice]
  func makeNSView(context:Context) -> MicrophonePopUpButton {
    MicrophonePopUpButton(frame:.zero,pullsDown:false)
  }
  func updateNSView(_ view:MicrophonePopUpButton,context:Context) {
    view.selectionChanged={ selection=$0 }
    view.update(devices:devices,selectedUID:selection)
  }
}
