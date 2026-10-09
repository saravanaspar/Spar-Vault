class DeviceSecurityStatus {
  const DeviceSecurityStatus({
    this.biometric = 'unsupported',
    this.screenLock = 'unsupported',
    this.autofillSupported = false,
    this.autofillSelected = false,
  });
  factory DeviceSecurityStatus.fromMap(Map<dynamic, dynamic>? value) =>
      DeviceSecurityStatus(
        biometric: value?['biometric'] as String? ?? 'unsupported',
        screenLock: value?['screenLock'] as String? ?? 'unsupported',
        autofillSupported: value?['autofillSupported'] == true,
        autofillSelected: value?['autofillSelected'] == true,
      );
  final String biometric, screenLock;
  final bool autofillSupported, autofillSelected;
  String authentication(bool deviceLock) => deviceLock ? screenLock : biometric;
  bool needsSetup(bool deviceLock) => [
    'not_enrolled',
    'permission',
    'not_enabled',
  ].contains(authentication(deviceLock));
  String explanation(bool deviceLock) => switch (authentication(deviceLock)) {
    'ready' =>
      deviceLock
          ? 'Use a strong fingerprint or your phone PIN, pattern or password.'
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
    'no_hardware' => 'A strong biometric sensor is unavailable. Try Phone screen lock instead.',
    _ => 'Hardware-backed quick unlock requires Android 11 or newer.',
  };
}
