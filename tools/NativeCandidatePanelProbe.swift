import AppKit

// Only panel callbacks are substituted. Rendering, theme/config loading and
// hit testing use the production sources, with an isolated real librime fixture.
final class SquirrelInputController {
  var specialCommentIndices: [ReservedPropertyKey: Set<Int>] = [:]
  func page(up: Bool) -> Bool { false }
  func moveCaret(forward: Bool) -> Bool { false }
  func selectCandidate(_ index: Int) -> Bool { false }
}

@main enum NativeCandidatePanelProbe {
  static func main() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory); app.finishLaunching()
    let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
    let files = FileManager.default
    try files.createDirectory(at:root,withIntermediateDirectories:true)
    let api = rime_get_api_stdbool().pointee
    var traits = RimeTraits.rimeStructInit()
    for key in [\RimeTraits.shared_data_dir, \RimeTraits.user_data_dir, \RimeTraits.log_dir] {
      traits.setCString(root.path,to:key)
    }
    traits.min_log_level = 2
    api.setup(&traits); api.initialize(&traits)
    defer { api.finalize() }
    var checks:[[String:Any]] = []
    func check(_ name:String,_ pass:Bool) { checks.append(["name":name,"passed":pass]) }
    try files.createDirectory(at:root.appendingPathComponent("build"),withIntermediateDirectories:true)
    let fixture = root.appendingPathComponent("build/squirrel.yaml")
    func writeConfig(_ format:String,showPaging:Bool) throws {
      try "style:\n  candidate_format: '\(format)'\n  show_paging: \(showPaging)\n  font_point: 16\n  hilited_corner_radius: 0\n  corner_radius: 2\n  color_scheme: native\n".write(to:fixture,atomically:true,encoding:.utf8)
    }
    let panel = SquirrelPanel(position:NSRect(x:300,y:300,width:1,height:20))
    let config = SquirrelConfig()
    if !CommandLine.arguments.contains("--skip-empty") {
    try writeConfig("",showPaging:false)
    guard config.openBaseConfig() else { fatalError("Fixture unavailable") }
    panel.load(config:config,forDarkMode:false); panel.load(config:config,forDarkMode:true)
    // Before the repair this empty row produces NSRange(1, -1) and traps.
    panel.update(preedit:"ni",selRange:NSRange(location:0,length:2),caretPos:2,
      candidates:["你"],comments:[""],labels:["a"],highlighted:0,page:0,lastPage:true,update:true)
    check("empty_candidate_format_does_not_crash",panel.isVisible && panel.frame.width.isFinite && panel.frame.height.isFinite)
    panel.hide(); config.close()
    if CommandLine.arguments.contains("--empty-only") { return }
    }

    let cached = SquirrelConfig()
    try writeConfig("[candidate]",showPaging:true)
    guard cached.openBaseConfig() else { fatalError("Fixture unavailable") }
    check("first_config_reads_original_value",cached.getBool("style/show_paging") == true)
    cached.close(); try writeConfig("[candidate]",showPaging:false)
    guard cached.openBaseConfig() else { fatalError("Changed fixture unavailable") }
    check("reopened_config_drops_previous_cache",cached.getBool("style/show_paging") == false)
    cached.close()

    try writeConfig("[candidate]",showPaging:true)
    guard config.openBaseConfig() else { fatalError("Fixture unavailable") }
    let view = SquirrelView(frame:NSRect(x:0,y:0,width:180,height:60))
    view.lightTheme.load(config:config,dark:false); view.darkTheme.load(config:config,dark:false)
    let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:16)]
    view.textContentStorage.attributedString = NSAttributedString(string:"测试候选",attributes:attributes)
    view.textContainer.size = NSSize(width:180,height:60)
    view.textLayoutManager.ensureLayout(for:view.textLayoutManager.documentRange)
    let row = NSRange(location:0,length:4)
    view.drawView(candidateRanges:[row],hilightedIndex:0,preeditRange:.empty,
      highlightedPreeditRange:.empty,canPageUp:true,canPageDown:true)
    view.draw(view.bounds)
    func arrowPoint(_ up:Bool) -> NSPoint? {
      for y in 0..<60 { for x in 0..<30 {
        let point = NSPoint(x:CGFloat(x),y:CGFloat(y))
        if view.click(at:point).2 == up { return point }
      } }
      return nil
    }
    let upPoint = arrowPoint(true), downPoint = arrowPoint(false)
    check("rendered_paging_arrows_have_hit_regions",upPoint != nil && downPoint != nil)
    view.drawView(candidateRanges:[row],hilightedIndex:0,preeditRange:.empty,
      highlightedPreeditRange:.empty,canPageUp:false,canPageDown:false)
    view.draw(view.bounds)
    check("disappeared_up_arrow_cannot_intercept_click",upPoint.map { view.click(at:$0).2 == nil } == true)
    check("disappeared_down_arrow_cannot_intercept_click",downPoint.map { view.click(at:$0).2 == nil } == true)
    check("square_highlight_has_finite_geometry",view.layer?.sublayers?.allSatisfy {
      guard let shape = $0 as? CAShapeLayer, let path = shape.path else { return true }
      return [path.boundingBox.minX,path.boundingBox.minY,path.boundingBox.width,path.boundingBox.height].allSatisfy { $0.isFinite }
    } == true)
    let report:[String:Any] = ["status":checks.allSatisfy { $0["passed"] as? Bool == true } ? "PASS" : "FAIL",
      "checks":checks,"microphone_used":false,"cloud_calls":0,"personal_dictionary_used":false,
      "scope":"Production native candidate rendering/configuration/hit testing; callback stubs; no installed IMK typing"]
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    if report["status"] as? String != "PASS" { exit(1) }
  }
}
