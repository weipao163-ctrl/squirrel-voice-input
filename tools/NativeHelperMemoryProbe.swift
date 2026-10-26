import AppKit
import SwiftUI
import EnhancementCore
import Darwin

// Real Helper/SwiftUI hierarchy; synthetic status changes only. No microphone,
// credentials, network requests, input-source switching or user data access.
@main enum NativeHelperMemoryProbe {
  static func footprint() -> UInt64 {
    var info=task_vm_info_data_t()
    var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result=withUnsafeMutablePointer(to:&info) { pointer in
      pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
        task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }
  static func pump(_ seconds:Double) {
    let until=Date(timeIntervalSinceNow:seconds)
    repeat {
      autoreleasepool {
        if let event=NSApp.nextEvent(matching:.any,until:Date(timeIntervalSinceNow:0.001),inMode:.default,dequeue:true) { NSApp.sendEvent(event) }
        NSApp.updateWindows()
      }
    } while Date()<until
  }
  static func main() throws {
    let app=NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
    let model=HelperModel(baseDirectory:base,automaticConnectionCheck:false,credentialLoader:{_ in fatalError("No credential reads permitted")})
    let window=autoreleasepool { SettingsWindow(model:model) }
    autoreleasepool { window.showWindow(nil) }; pump(0.8)
    let mode=CommandLine.arguments.count>2 ? CommandLine.arguments[2] : "closed"
    weak var previousContent=window.window?.contentView
    autoreleasepool {
      if mode == "closed" { window.window?.close() }
      else if mode == "hidden" { window.window?.orderOut(nil) }
      else if mode == "miniaturized" { window.window?.miniaturize(nil) }
    }
    pump(0.2)
    var checks:[[String:Any]]=[]
    func check(_ name:String,_ passed:Bool) { checks.append(["name":name,"passed":passed]) }
    if mode != "visible" { check("hidden_hosting_tree_detached",window.window?.contentView !== previousContent && !(window.window?.contentView is NSHostingView<SettingsView>)) }
    model.settingsTab=2
    let savedDraft=model.draft
    var samples:[[String:Any]]=[["updates":0,"footprint":footprint()]]
    for batch in 1...6 {
      for i in 0..<1000 {
        autoreleasepool {
          model.level=Double(i%100)/100
          model.status="离线压力测试 \(batch*1000+i)"
        }
        pump(0.001)
      }
      samples.append(["updates":batch*1000,"footprint":footprint()])
    }
    window.window?.orderOut(nil); pump(0.3)
    let warm=samples[1]["footprint"] as! UInt64
    let end=samples.last!["footprint"] as! UInt64
    check("post_warmup_growth_below_8_MiB",end <= warm+8*1024*1024)
    if window.window?.isMiniaturized == true { window.window?.deminiaturize(nil) }
    window.showWindow(nil); pump(0.2)
    check("reopening_restores_hosting_view",window.window?.contentView is NSHostingView<SettingsView>)
    check("draft_and_tab_survive_detachment",model.draft == savedDraft && model.settingsTab == 2)
    window.window?.close(); pump(0.1)
    let beforeCycles=footprint()
    for _ in 0..<20 {
      autoreleasepool {
        window.showWindow(nil)
        window.window?.layoutIfNeeded()
        window.window?.close()
      }
      pump(0.01)
    }
    pump(0.3)
    check("repeated_open_close_growth_below_8_MiB",footprint() <= beforeCycles+8*1024*1024)
    let report:[String:Any] = ["status":checks.allSatisfy{$0["passed"] as? Bool == true} ? "PASS" : "FAIL",
      "checks":checks,"mode":mode,"samples":samples,"microphone":false,"network":false,"pid":getpid()]
    print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
  }
}
