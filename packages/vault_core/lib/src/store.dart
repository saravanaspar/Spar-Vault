abstract interface class VaultStore {
  Future<String?> read();

  /// Atomic compare-and-swap. Only ciphertext ever reaches this boundary.
  /// Refuses to overwrite a different persisted snapshot.
  Future<void> write(String encrypted, {required String? expected});
}

class ConcurrentVaultChange implements Exception {
  const ConcurrentVaultChange();
  @override
  String toString() =>
      'The vault changed in another window. Lock and reopen it.';
}
