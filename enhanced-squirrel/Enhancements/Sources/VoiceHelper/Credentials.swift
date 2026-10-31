import Foundation
import Security
import EnhancementCore

// Carries only a system error code, never the account reference or secret.
struct CredentialReadFailure: LocalizedError {
  let status: OSStatus?
  var errorDescription: String? {
    if let status { return "钥匙串读取失败（OSStatus \(status)）。" }
    return "已保存密钥的数据无法读取。"
  }
  static func sanitized(_ error: Error) -> Self {
    (error as? Self) ?? Self(status: nil)
  }
}

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
    guard status == errSecSuccess else { throw CredentialReadFailure(status: status) }
    guard let data = output as? Data, let key = String(data: data, encoding: .utf8) else {
      throw CredentialReadFailure(status: nil)
    }
    do { try VoiceCredential.validate(key) }
    catch { throw CredentialReadFailure(status: nil) }
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
