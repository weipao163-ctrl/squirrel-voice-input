import Foundation
import Security
import EnhancementCore

final class CredentialStore {
  private let service = "org.rime.SquirrelEnhanced.Development.voice"
  func put(_ key: String) throws -> String {
    try VoiceCredential.validate(key)
    let ref = UUID().uuidString
    let item: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
                             kSecAttrService as String:service, kSecAttrAccount as String:ref,
                             kSecValueData as String:Data(key.utf8),
                             kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw SettingsError.invalid("Keychain 保存失败（\(status)）。") }
    return ref
  }
  func get(_ ref: String) throws -> String {
    var output: CFTypeRef?
    // Called only on HelperModel's background credential queue. Let macOS ask
    // the user for its existing Keychain ACL permission after an app update;
    // suppressing that permission made saved keys permanently unreadable.
    // The main-thread deadline reports waiting without discarding a late grant.
    let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
                              kSecAttrService as String:service,kSecAttrAccount as String:ref,
                              kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
    let status = SecItemCopyMatching(query as CFDictionary, &output)
    guard status == errSecSuccess, let data = output as? Data,
          let key = String(data: data, encoding: .utf8) else {
      throw SettingsError.invalid("Keychain 无法读取（\(status)）；请在设置中重新保存 Key，不在按键路径弹框。")
    }
    try VoiceCredential.validate(key)
    return key
  }
  func remove(_ ref: String) throws {
    let status = SecItemDelete([kSecClass as String:kSecClassGenericPassword,
                               kSecAttrService as String:service, kSecAttrAccount as String:ref] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SettingsError.invalid("Keychain 删除失败（\(status)）。")
    }
  }
}
