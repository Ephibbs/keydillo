import Foundation
import Security
import LocalAuthentication

let group = "2JARAJYAYY.com.studiokillswitch.keydillo.spike"
let args = CommandLine.arguments
func baseQuery(_ name: String) -> [String: Any] {
  [kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: "keydillo-spike",
   kSecAttrAccount as String: name,
   kSecUseDataProtectionKeychain as String: true,
   kSecAttrAccessGroup as String: group]
}
switch args.dropFirst().first {
case "store":
  let name = args[2]
  SecItemDelete(baseQuery(name) as CFDictionary)
  var err: Unmanaged<CFError>?
  let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &err)!
  var q = baseQuery(name)
  q[kSecValueData as String] = Data("SPIKE-SECRET-\(name)".utf8)
  q[kSecAttrAccessControl as String] = ac
  print("store:", SecItemAdd(q as CFDictionary, nil))
case "read":
  var q = baseQuery(args[2])
  q[kSecReturnData as String] = true
  let ctx = LAContext(); ctx.localizedReason = "read spike secret"
  q[kSecUseAuthenticationContext as String] = ctx
  var out: CFTypeRef?
  let s = SecItemCopyMatching(q as CFDictionary, &out)
  print("read:", s, (out as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "nil")
default: print("usage: store|read <name>")
}
exit(0)
