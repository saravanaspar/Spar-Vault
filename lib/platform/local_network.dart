class LocalNetworkChoice {
  const LocalNetworkChoice(this.address, this.interfaceName);
  final String address, interfaceName;
  String get label {
    final name = interfaceName.toLowerCase();
    if (name.startsWith('wlan') ||
        name.startsWith('wlp') ||
        name.contains('wi-fi') ||
        name.contains('wireless')) {
      return 'Wi-Fi';
    }
    if (name.startsWith('eth') ||
        name.startsWith('enp') ||
        name.contains('ethernet')) {
      return 'Ethernet';
    }
    final clean = interfaceName.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    return clean.isEmpty
        ? 'Local network'
        : clean.substring(0, clean.length.clamp(0, 80));
  }
}
