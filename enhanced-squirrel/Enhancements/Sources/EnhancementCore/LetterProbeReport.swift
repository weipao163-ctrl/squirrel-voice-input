import Foundation

// Validates the complete, isolated native worker's output before the GUI can
// display success. It does NOT prove rendered UI, physical keys or user-schema
// compatibility; those scopes are deliberately absent from the result.
public struct LetterProbeReport: Codable, Equatable, Sendable {
  public struct Case: Codable, Equatable, Sendable {
    public let name: String
    public let status: String
    public let error: String
  }
  public static let requiredNames: Set<String> = [
    "pinyin_and_first_space", "alphabet_is_pinyin_before_selection",
    "selection_letters_current_page", "second_space_confirms_highlight",
    "second_page_letter", "last_page_missing_item", "escape_retains_input",
    "backspace_exactly_once", "numeric_current_page", "mouse_current_page_API",
    "sentence_partial_selection", "ASCII_and_shortcut_passthrough",
    "disable_restores_original_labels", "independent_session_cleanup"
  ]
  public let format: Int
  public let kind, status, version, keys: String
  public let hide: Bool
  public let pageSize: Int
  public let macOSUITested: Bool
  public let networkCalls: Int
  public let userDictionaryUsed: Bool
  public let isolationVerified: Bool
  public let passed, failed, skipped: Int
  public let fatal: String
  public let tests: [Case]
  private enum CodingKeys: String, CodingKey {
    case format, kind, status, version, keys, hide, passed, failed, skipped, fatal, tests
    case pageSize = "page_size", macOSUITested = "macOS_UI_tested"
    case networkCalls = "network_calls", userDictionaryUsed = "user_dictionary_used"
    case isolationVerified = "isolation_verified"
  }
  public static func decode(_ data: Data) throws -> LetterProbeReport {
    guard !data.isEmpty, data.count <= 256 * 1024 else {
      throw SettingsError.invalid("字母自测报告为空或超限；未报告成功。")
    }
    return try JSONDecoder().decode(Self.self, from:data)
  }
  public func validatedSummary(expectedKeys: String, expectedHide: Bool) throws -> String {
    let applicableSkip = expectedKeys.count == 1 ? 1 : 0
    let actualPass = tests.filter { $0.status == "PASS" }.count
    let actualSkip = tests.filter { $0.status == "N/A" }.count
    guard format == 1, kind == "real_librime_C_API_fixture", status == "PASS",
          keys == expectedKeys, hide == expectedHide, (1...9).contains(pageSize),
          pageSize == expectedKeys.utf8.count, Set(expectedKeys).count == pageSize,
          expectedKeys.utf8.allSatisfy({ (97...122).contains($0) }),
          !version.isEmpty, version.utf8.count <= 64, !macOSUITested,
          networkCalls == 0, !userDictionaryUsed, isolationVerified, fatal.isEmpty,
          tests.count == Self.requiredNames.count,
          Set(tests.map(\.name)) == Self.requiredNames,
          passed == actualPass, failed == 0, skipped == actualSkip,
          actualSkip == applicableSkip, actualPass + actualSkip == tests.count,
          tests.allSatisfy({ $0.status == "PASS" && $0.error.isEmpty ||
            $0.status == "N/A" && $0.name == "last_page_missing_item" && pageSize == 1 }) else {
      throw SettingsError.invalid("字母自测报告与本次配置/完整用例集合不一致，或存在失败；未报告通过。")
    }
    let partial = actualSkip == 0 ? "" : "；页大小 1 无非空末页缺项，1 项不适用"
    return "独立进程真实 Rime \(version) 固定测试词库：\(actualPass) 项通过\(partial)。覆盖首次空格、所有选词字母、第二次空格、第二页/末页、Esc、退格、分段、数字、鼠标 C API、关闭与状态清理。仅算法/配置测试；不是当前用户方案完整兼容、GUI 渲染、真实鼠标或物理重复按键验收。"
  }
}
