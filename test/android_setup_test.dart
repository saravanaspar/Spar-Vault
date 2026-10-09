import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spar_vault/main.dart';
import 'package:spar_vault/platform/integrations.dart';
import 'package:spar_vault/platform/local_network.dart';
import 'package:spar_vault/ui/widgets.dart';
import 'package:vault_core/vault_core.dart';

class MemoryStore implements VaultStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String encrypted, {required String? expected}) async {
    if (expected != value) throw const ConcurrentVaultChange();
    value = encrypted;
  }
}

class AndroidIntegrations extends PlatformIntegrations {
  String biometricStatus = 'ready', screenStatus = 'ready';
  bool biometricBound = false, deviceBound = false, selected = false;
  bool acceptSetup = false, acceptAutofill = false;
  int setupRequests = 0,
      autofillRequests = 0,
      cancellations = 0,
      enrollments = 0;
  Completer<void>? enrollment;
  Completer<Uint8List?>? unlocking;
  Uint8List? passedKey;
  @override
  bool get isAndroid => true;
  @override
  bool get isDesktop => false;
  @override
  Future<DeviceSecurityStatus> deviceSecurityStatus() async =>
      DeviceSecurityStatus(
        biometric: biometricStatus,
        screenLock: screenStatus,
        autofillSupported: true,
        autofillSelected: selected,
      );
  @override
  Future<bool> biometricEnabled(String id) async => biometricBound;
  @override
  Future<bool> deviceUnlockEnabled(String id) async => deviceBound;
  @override
  Future<bool> requestAuthenticationSetup(bool deviceLock) async {
    setupRequests++;
    if (acceptSetup) {
      if (deviceLock) {
        screenStatus = 'ready';
      } else {
        biometricStatus = 'ready';
      }
    }
    return acceptSetup;
  }

  @override
  Future<bool> requestAutofill() async {
    autofillRequests++;
    selected = acceptAutofill;
    return selected;
  }

  @override
  Future<void> enableBiometric(String id, Uint8List key) async {
    enrollments++;
    passedKey = key;
    await enrollment?.future;
    biometricBound = true;
  }

  @override
  Future<void> enableDeviceUnlock(String id, Uint8List key) async {
    enrollments++;
    passedKey = key;
    await enrollment?.future;
    deviceBound = true;
  }

  @override
  Future<Uint8List?> unlockDevice(String id) async => unlocking?.future;
  @override
  Future<void> cancelBiometric() async {
    cancellations++;
    if (enrollment != null && !enrollment!.isCompleted) {
      enrollment!.completeError(
        PlatformException(
          code: 'cancelled',
          message: 'Android authentication was cancelled.',
        ),
      );
    }
    if (unlocking != null && !unlocking!.isCompleted) {
      unlocking!.completeError(
        PlatformException(
          code: 'cancelled',
          message: 'Android authentication was cancelled.',
        ),
      );
    }
  }

  @override
  Future<void> clearBiometric() async {
    biometricBound = false;
  }

  @override
  Future<void> clearDeviceUnlock() async {
    deviceBound = false;
  }

  @override
  Future<void> updateAutofill(
    List<VaultEntry> entries,
    VaultPreferences prefs,
    DateTime deadline,
  ) async {}
  @override
  Future<void> clearAutofill() async {}
}

Future<MemoryStore> seed(MasterKey key, {bool strict = false}) async {
  final store = MemoryStore();
  store.value = await VaultCodec().seal(
    VaultData(
      createdAt: DateTime.utc(2026),
      entries: [
        VaultEntry(
          id: 'a' * 32,
          title: 'Private account',
          username: 'person@example.test',
          updatedAt: DateTime.utc(2026),
        ),
      ],
      preferences: VaultPreferences(lockOnBackground: strict),
    ),
    key,
    vaultId: 'b' * 32,
    revision: 1,
  );
  return store;
}

Future<void> wide(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

Future<void> unlock(WidgetTester tester, MasterKey key) async {
  await tester.enterText(find.byType(TextField).first, key.display());
  await tester.tap(find.text('Unlock vault'));
  await tester.pumpAndSettle();
}

Future<void> settings(WidgetTester tester) async {
  await tester.tap(find.text('Settings').first);
  await tester.pumpAndSettle();
}

Future<void> click(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  test('network labels are readable and bounded', () {
    expect(const LocalNetworkChoice('192.168.1.2', 'wlan0').label, 'Wi-Fi');
    expect(
      const LocalNetworkChoice('192.168.1.2', 'Ethernet 2').label,
      'Ethernet',
    );
    expect(
      LocalNetworkChoice('192.168.1.2', '\u0000${'z' * 100}').label.length,
      80,
    );
  });

  testWidgets(
    'receive dialog handles phone keyboard, cancel and invalid code without UI errors',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(SparVaultApp(store: MemoryStore()));
      await tester.pumpAndSettle();
      await click(tester, 'Receive encrypted transfer file');
      await tester.enterText(
        find.descendant(
          of: find.byType(TransferCodeDialog),
          matching: find.byType(TextField),
        ),
        'invalid private code',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      await click(tester, 'Continue');
      expect(
        find.text('Use the full transfer code from the sending device.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await click(tester, 'Receive encrypted transfer file');
      await tester.enterText(find.byType(TextField), 'discard me');
      await click(tester, 'Cancel');
      expect(find.text('discard me'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'missing fingerprint enrollment opens Android setup before any wrapping attempt',
    (tester) async {
      await wide(tester);
      final key = MasterKey.generate(),
          integrations = AndroidIntegrations()
            ..biometricStatus = 'not_enrolled';
      final store = await seed(key);
      await tester.pumpWidget(
        SparVaultApp(store: store, integrations: integrations),
      );
      await tester.pumpAndSettle();
      await unlock(tester, key);
      await settings(tester);
      await click(tester, 'Enable biometric unlock');
      expect(find.text('Set up Android authentication'), findsOneWidget);
      await click(tester, 'Continue');
      expect(integrations.setupRequests, 1);
      expect(integrations.enrollments, 0);
      expect(find.text('Set up Android authentication'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      key.destroy();
    },
  );

  testWidgets(
    'a blocked permission routes through Android setup and can then enroll',
    (tester) async {
      await wide(tester);
      final key = MasterKey.generate(),
          integrations = AndroidIntegrations()
            ..biometricStatus = 'permission'
            ..acceptSetup = true;
      await tester.pumpWidget(
        SparVaultApp(store: await seed(key), integrations: integrations),
      );
      await tester.pumpAndSettle();
      await unlock(tester, key);
      await settings(tester);
      await click(tester, 'Enable biometric unlock');
      await click(tester, 'Continue');
      expect(find.text('Enable fingerprint / face unlock?'), findsOneWidget);
      await click(tester, 'Continue');
      expect(integrations.setupRequests, 1);
      expect(integrations.enrollments, 1);
      expect(integrations.biometricBound, isTrue);
      expect(integrations.passedKey!.every((b) => b == 0), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      key.destroy();
    },
  );

  testWidgets(
    'own system prompt is not cancelled by strict background locking',
    (tester) async {
      await wide(tester);
      final key = MasterKey.generate(),
          integrations = AndroidIntegrations()..enrollment = Completer<void>();
      await tester.pumpWidget(
        SparVaultApp(
          store: await seed(key, strict: true),
          integrations: integrations,
        ),
      );
      await tester.pumpAndSettle();
      await unlock(tester, key);
      await settings(tester);
      await click(tester, 'Enable Phone screen lock');
      await click(tester, 'Continue');
      expect(integrations.enrollments, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(integrations.cancellations, 0);
      integrations.enrollment!.complete();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(integrations.deviceBound, isTrue);
      expect(find.text('Remove Phone screen lock'), findsOneWidget);
      expect(integrations.passedKey!.every((b) => b == 0), isTrue);
      // A subsequent actual minimize still locks immediately.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Unlock vault'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      key.destroy();
    },
  );

  testWidgets(
    'inactivity still cancels a pending system enrollment and wipes its bytes',
    (tester) async {
      await wide(tester);
      final key = MasterKey.generate(),
          integrations = AndroidIntegrations()..enrollment = Completer<void>();
      var clock = DateTime.utc(2026);
      await tester.pumpWidget(
        SparVaultApp(
          store: await seed(key),
          integrations: integrations,
          now: () => clock,
        ),
      );
      await tester.pumpAndSettle();
      await unlock(tester, key);
      await settings(tester);
      await click(tester, 'Enable biometric unlock');
      await click(tester, 'Continue');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      clock = clock.add(const Duration(minutes: 6));
      await tester.pump(const Duration(minutes: 6));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(integrations.cancellations, greaterThan(0));
      expect(integrations.biometricBound, isFalse);
      expect(integrations.passedKey!.every((b) => b == 0), isTrue);
      expect(find.text('Unlock vault'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      key.destroy();
    },
  );

  testWidgets(
    'screen lock unlock waits for foreground and never stores its raw key',
    (tester) async {
      await wide(tester);
      final key = MasterKey.generate(),
          integrations = AndroidIntegrations()
            ..deviceBound = true
            ..unlocking = Completer<Uint8List?>();
      final store = await seed(key);
      final encrypted = store.value;
      await tester.pumpWidget(
        SparVaultApp(store: store, integrations: integrations),
      );
      await tester.pumpAndSettle();
      await click(tester, 'Unlock with Phone screen lock');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      final bytes = key.copyBytes();
      integrations.unlocking!.complete(bytes);
      await tester.pump();
      expect(find.text('Private account'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Private account'), findsOneWidget);
      expect(bytes.every((b) => b == 0), isTrue);
      expect(store.value, encrypted);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      key.destroy();
    },
  );

  testWidgets(
    'autofill asks Android on first enable and stays off after rejection',
    (tester) async {
      await wide(tester);
      final key = MasterKey.generate(), integrations = AndroidIntegrations();
      final store = await seed(key);
      await tester.pumpWidget(
        SparVaultApp(store: store, integrations: integrations),
      );
      await tester.pumpAndSettle();
      await unlock(tester, key);
      await settings(tester);
      await click(tester, 'Allow confirmed autofill while unlocked');
      expect(integrations.autofillRequests, 1);
      final opened = await VaultCodec().open(
        VaultBundle.parse(store.value!).vault,
        key,
      );
      expect(opened.preferences.autofillEnabled, isFalse);
      expect(find.textContaining('Autofill was not enabled.'), findsOneWidget);
      integrations.acceptAutofill = true;
      await click(tester, 'Allow confirmed autofill while unlocked');
      expect(integrations.autofillRequests, 2);
      final accepted = await VaultCodec().open(
        VaultBundle.parse(store.value!).vault,
        key,
      );
      expect(accepted.preferences.autofillEnabled, isTrue);
      expect(find.text('Android service: Spar Vault selected'), findsOneWidget);
      integrations.selected = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('Autofill is paused.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      key.destroy();
    },
  );
}
