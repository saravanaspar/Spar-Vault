class DeviceSecurityStatus {
  const DeviceSecurityStatus({
    this.biometric = 'unsupported',
    this.screenLock = 'unsupported',
    this.systemProvider = 'android',
    this.autofillSupported = false,
    this.autofillSelected = false,
  });
  factory DeviceSecurityStatus.fromMap(Map<dynamic, dynamic>? value) =>
      DeviceSecurityStatus(
        biometric: value?['biometric'] as String? ?? 'unsupported',
        screenLock: value?['screenLock'] as String? ?? 'unsupported',
        systemProvider: value?['systemProvider'] as String? ?? 'android',
        autofillSupported: value?['autofillSupported'] == true,
        autofillSelected: value?['autofillSelected'] == true,
      );
  final String biometric, screenLock, systemProvider;
  final bool autofillSupported, autofillSelected;
  String get systemDescription => switch (systemProvider) {
    'windows' => 'Windows Hello protects the vault key with a hardware-backed key and requires authentication for each unlock.',
    'macos' => 'The macOS Data Protection Keychain releases the vault key only after Touch ID or device-password authentication.',
    'fido2' => 'Linux System lock uses a FIDO2 security key with a configured PIN, touch and hmac-secret support. The Linux login password alone is not used.',
    _ => 'Android hardware protects a wrapped vault key. Your strong fingerprint or phone PIN, pattern or password can unlock it.',
  };
  String authentication(bool deviceLock) => deviceLock ? screenLock : biometric;
  bool needsSetup(bool deviceLock) => [
    'not_enrolled',
    'permission',
    'not_enabled',
  ].contains(authentication(deviceLock));
  String explanation(bool deviceLock) {
    if (deviceLock && systemProvider != 'android') {
      return switch (screenLock) {
        'ready' => systemDescription,
        'signing_required' => 'System lock needs an application signed with a valid macOS application identifier and Keychain entitlements.',
        'not_enrolled' =>
          'Set up Windows Hello in system sign-in settings first.',
        'no_hardware' =>
          systemProvider == 'fido2'
              ? 'Connect a FIDO2 security key with a PIN and hmac-secret support.'
              : 'Hardware-backed Windows Hello is unavailable on this device.',
        _ => 'System authentication is unavailable. Use your vault password or secure key.',
      };
    }
    return switch (authentication(deviceLock)) {
      'ready' =>
        deviceLock
            ? systemDescription
            : 'Use a strong fingerprint or face scan.',
      'not_enrolled' =>
        deviceLock
            ? 'Set a PIN, pattern or password in Android first.'
            : 'Enroll a strong fingerprint in Android first.',
      'permission' =>
        'Android blocked biometric access. Review the app settings.',
      'not_enabled' => 'Allow biometrics for apps in Android settings.',
      'temporarily_unavailable' => 'Android authentication is temporarily unavailable. Retry or use your vault password/key.',
      'security_update' =>
        'Android requires a security update before this sensor can be used.',
      'no_hardware' =>
        'A strong biometric sensor is unavailable. Try System lock instead.',
      _ => 'Hardware-backed quick unlock requires Android 11 or newer.',
    };
  }
}
