import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "sable/privacy",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "protectVaultDirectory",
            let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
      var directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
      guard directory.path.hasPrefix(support.standardizedFileURL.path + "/") else {
        result(FlutterError(code: "invalid_path", message: "Invalid vault directory", details: nil))
        return
      }
      do {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.complete], atPath: directory.path)
        result(nil)
      } catch {
        result(FlutterError(code: "privacy_failed", message: "Cannot protect vault storage", details: nil))
      }
    }
  }
}
