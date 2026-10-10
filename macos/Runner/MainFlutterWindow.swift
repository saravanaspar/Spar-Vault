import Cocoa
import FlutterMacOS
import LocalAuthentication
import Security

class MainFlutterWindow: NSWindow {
  private var systemLock: MacSystemLock?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    RegisterGeneratedPlugins(registry: flutterViewController)
    systemLock = MacSystemLock(flutterViewController.engine.binaryMessenger)
    super.awakeFromNib()
  }
}

private final class MacSystemLock {
  private let service = "com.bnstechsystems.sable_vault.system-lock.v1"
  private let preference = "SparVaultSystemLockAccount"
  private var context: LAContext?
  private var pending: FlutterResult?
  private var generation = 0
  private let channel: FlutterMethodChannel

  init(_ messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "spar/system_lock", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "closed", message: "Application closed.", details: nil)); return }
      self.handle(call, result)
    }
  }
  private func signed() -> Bool {
    guard let task = SecTaskCreateFromSelf(nil),
          let value = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String else { return false }
    return !value.isEmpty
  }
  private func base(_ account: String? = nil) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false
    ]
    if let account = account { q[kSecAttrAccount as String] = account }
    return q
  }
  private func account(_ id: String) -> String? {
    guard let saved = UserDefaults.standard.string(forKey: preference),
          saved.hasPrefix(id + "|"), saved.count == 69 else { return nil }
    return saved
  }
  private func read(_ account: String, _ context: LAContext) throws -> Data {
    var q = base(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    q[kSecUseAuthenticationContext as String] = context
    q[kSecUseOperationPrompt as String] = "Unlock Spar Vault with System lock"
    var value: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &value)
    guard status == errSecSuccess, let bytes = value as? Data, bytes.count == 32 else {
      throw NSError(domain: service, code: Int(status))
    }
    return bytes
  }
  private func wipe(_ data: inout Data) {
    data.withUnsafeMutableBytes { buffer in
      if let ptr = buffer.baseAddress { memset(ptr, 0, buffer.count) }
    }
  }
  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    if call.method == "cancel" {
      generation += 1; context?.invalidate()
      pending?(FlutterError(code: "cancelled", message: "System authentication was cancelled.", details: nil))
      pending = nil; result(nil); return
    }
    if call.method == "setup" {
      if let url = URL(string: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension") { NSWorkspace.shared.open(url) }
      result(true); return
    }
    if call.method == "status" {
      let ctx = LAContext(); var error: NSError?
      let ready = signed() ? (ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) ? "ready" : "unsupported") : "signing_required"
      result(["systemProvider": "macos", "screenLock": ready]); return
    }
    if call.method == "clear" {
      generation += 1; context?.invalidate()
      pending?(FlutterError(code: "cancelled", message: "System authentication was cancelled.", details: nil)); pending = nil
      let status = SecItemDelete(base() as CFDictionary)
      if status != errSecSuccess && status != errSecItemNotFound {
        result(FlutterError(code: "keychain", message: "Cannot remove the System lock binding.", details: nil)); return
      }
      UserDefaults.standard.removeObject(forKey: preference); result(nil); return
    }
    guard ["enable", "unlock", "enabled"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
    guard let args = call.arguments as? [String: Any], let id = args["vaultId"] as? String,
          id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
      result(FlutterError(code: "invalid", message: "Invalid vault identifier.", details: nil)); return
    }
    if call.method == "enabled" { result(account(id) != nil); return }
    guard signed() else { result(FlutterError(code: "signing", message: "Sign the macOS app with an application identifier and Keychain entitlements first.", details: nil)); return }
    guard context == nil else { result(FlutterError(code: "busy", message: "System authentication is already running.", details: nil)); return }
    let enroll = call.method == "enable"
    let oldAccount = UserDefaults.standard.string(forKey: preference)
    let unlockAccount = account(id)
    let newAccount = id + "|" + UUID().uuidString
    guard enroll || account(id) != nil else { result(nil); return }
    var root = (args["key"] as? FlutterStandardTypedData)?.data ?? Data()
    if enroll && root.count != 32 { result(FlutterError(code: "invalid", message: "Invalid System lock key.", details: nil)); return }
    let ctx = LAContext()
    ctx.touchIDAuthenticationAllowableReuseDuration = 0
    ctx.localizedReason = "Unlock Spar Vault with System lock"
    context = ctx; pending = result; let token = generation
    DispatchQueue.global(qos: .userInitiated).async {
      var output = Data(); var failure = false; var created = false
      do {
        if enroll {
          var error: Unmanaged<CFError>?
          guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
            throw NSError(domain: self.service, code: -1)
          }
          var q = self.base(newAccount)
          q[kSecAttrAccessControl as String] = access
          q[kSecValueData as String] = root
          let status = SecItemAdd(q as CFDictionary, nil)
          guard status == errSecSuccess else { throw NSError(domain: self.service, code: Int(status)) }
          created = true
          output = try self.read(newAccount, ctx)
          guard output == root else { throw NSError(domain: self.service, code: -1) }
        } else {
          output = try self.read(unlockAccount!, ctx)
        }
      } catch { failure = true }
      self.wipe(&root)
      DispatchQueue.main.async {
        let cancelled = self.generation != token
        if failure || cancelled {
          if created { SecItemDelete(self.base(newAccount) as CFDictionary) }
          if !cancelled { self.pending?(FlutterError(code: "keychain", message: "Keychain authentication did not complete. Use your vault password or secure key.", details: nil)) }
        } else if enroll {
          UserDefaults.standard.set(newAccount, forKey: self.preference)
          if let old = oldAccount { SecItemDelete(self.base(old) as CFDictionary) }
          self.pending?(nil)
        } else {
          self.pending?(FlutterStandardTypedData(bytes: output))
        }
        self.wipe(&output)
        self.pending = nil; self.context = nil
      }
    }
  }
}

