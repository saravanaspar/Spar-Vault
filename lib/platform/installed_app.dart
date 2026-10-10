class InstalledApp {
  const InstalledApp(this.package, this.name);
  final String package, name;
  factory InstalledApp.fromMap(Map<dynamic, dynamic> value) {
    final package = value['package'], name = value['name'];
    if (package is! String ||
        name is! String ||
        package.length > 200 ||
        name.length > 200 ||
        !RegExp(r'^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$').hasMatch(package)) {
      throw const FormatException('Android returned an invalid app.');
    }
    return InstalledApp(package, name);
  }
}
