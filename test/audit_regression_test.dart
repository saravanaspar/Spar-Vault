import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spar_vault/app/vault_controller.dart';
import 'package:spar_vault/main.dart';
import 'package:spar_vault/platform/integrations.dart';
import 'package:spar_vault/ui/entry_editor.dart';
import 'package:spar_vault/ui/widgets.dart';
import 'package:vault_core/vault_core.dart';

class AuditStore implements VaultStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String encrypted, {required String? expected}) async {
    if (value != expected) throw const ConcurrentVaultChange();
    value = encrypted;
  }
}

class RetryBackups extends PlatformIntegrations {
  int writes = 0;
  @override
  Future<void> writeBackup(String directory, String snapshot, String id) async {
    writes++;
    if (writes == 1) throw StateError('Synthetic provider failure');
  }
}

class EditorAndroidIntegrations extends PlatformIntegrations {
  @override
  bool get isAndroid => true;
  @override
  Future<List<InstalledApp>> installedApps() async => [
    const InstalledApp('com.example.mail', 'Example Mail'),
  ];
  @override
  Future<List<String>> certificates(String package) async =>
      package == 'com.example.mail' ? ['b' * 64] : [];
}

Finder editorField(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> editorTab(WidgetTester tester, String label) async {
  final tab = find.widgetWithText(Tab, label);
  await tester.ensureVisible(tab);
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

Future<void> openEditor(
  WidgetTester tester, {
  VaultEntry? entry,
  EntryKind initialKind = EntryKind.login,
  required ValueChanged<VaultEntry?> onSaved,
  Future<void> Function(String)? onCopied,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              onSaved(
                await showDialog<VaultEntry>(
                  context: context,
                  builder: (_) => EntryEditor(
                    entry: entry,
                    initialKind: initialKind,
                    touch: () {},
                    integrations: EditorAndroidIntegrations(),
                    copy: onCopied ?? (_) async {},
                  ),
                ),
              );
            },
            child: const Text('Open editor'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'generated password can be revealed, copied and saved on mobile',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      VaultEntry? saved;
      String? copied;
      await openEditor(
        tester,
        onSaved: (value) => saved = value,
        onCopied: (value) async => copied = value,
      );
      await tester.enterText(editorField('Title'), 'New login');
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Copy password'),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('Generate 24-character password'));
      await tester.tap(find.text('Generate 24-character password'));
      await tester.pumpAndSettle();
      final generated = tester
          .widget<TextField>(editorField('Password'))
          .controller!
          .text;
      expect(generated.length, 24);
      expect(
        tester.widget<TextField>(editorField('Password')).obscureText,
        isTrue,
      );
      await tester.ensureVisible(find.text('Copy password'));
      await tester.tap(find.text('Copy password'));
      await tester.pumpAndSettle();
      expect(copied, generated);
      await tester.ensureVisible(
        find.byTooltip('Show password for 20 seconds'),
      );
      await tester.tap(find.byTooltip('Show password for 20 seconds'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(editorField('Password')).obscureText,
        isFalse,
      );
      await tester.pump(const Duration(seconds: 21));
      expect(
        tester.widget<TextField>(editorField('Password')).obscureText,
        isTrue,
      );
      await tester.tap(find.byTooltip('Show password for 20 seconds'));
      await tester.pumpAndSettle();
      await editorTab(tester, 'Extra notes');
      await editorTab(tester, 'Login');
      expect(
        tester.widget<TextField>(editorField('Password')).obscureText,
        isTrue,
      );
      await tester.tap(find.text('Save item'));
      await tester.pumpAndSettle();
      expect(saved!.password, generated);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('mobile Security empty rows wrap without pixel overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final key = MasterKey.generate(), store = AuditStore();
    store.value = await VaultCodec().seal(
      VaultData(createdAt: DateTime.utc(2026), entries: []),
      key,
      vaultId: 'a' * 32,
      revision: 1,
    );
    await tester.pumpWidget(SparVaultApp(store: store));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, key.display());
    await tester.tap(find.text('Unlock vault'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Security').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('No short passwords found (all >= 16 chars).'),
      160,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    key.destroy();
  });

  testWidgets('Autofill selects an installed app without package text entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    VaultEntry? saved;
    await openEditor(tester, onSaved: (value) => saved = value);
    await tester.enterText(editorField('Title'), 'Mail');
    await editorTab(tester, 'Autofill');
    expect(
      editorField('Installed app package, e.g. com.example.app'),
      findsNothing,
    );
    await tester.tap(find.text('Choose installed app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Example Mail'));
    await tester.pumpAndSettle();
    expect(find.text('Example Mail'), findsOneWidget);
    await tester.tap(find.text('Save item'));
    await tester.pumpAndSettle();
    expect(saved!.androidPackage, 'com.example.mail');
    expect(saved!.androidCertificates, ['b' * 64]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'secure note opens directly without login fields or duplicate notes tab',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      VaultEntry? saved;
      await openEditor(
        tester,
        initialKind: EntryKind.note,
        onSaved: (value) => saved = value,
      );
      expect(editorField('Password'), findsNothing);
      expect(find.widgetWithText(Tab, 'Extra notes'), findsNothing);
      await tester.enterText(editorField('Title'), 'Private note');
      await tester.ensureVisible(editorField('Secure note'));
      await tester.enterText(editorField('Secure note'), 'My note');
      await tester.ensureVisible(find.text('Save item'));
      await tester.tap(find.text('Save item'));
      await tester.pumpAndSettle();
      expect(saved!.kind, EntryKind.note);
      expect(saved!.notes, 'My note');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile item tabs preserve edits and hidden attachment/binding data',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final original = VaultEntry(
        id: randomId(),
        title: 'Account',
        username: 'before@example.test',
        password: 'Keep this password',
        notes: 'Old note',
        totp: 'otpauth://totp/account?secret=JBSWY3DPEHPK3PXP&period=60',
        favorite: true,
        updatedAt: DateTime.utc(2026),
        attachments: [
          VaultAttachment(
            id: randomId(),
            name: 'proof.txt',
            base64Bytes: 'aGk=',
          ),
        ],
        androidPackage: 'com.example.app',
        androidCertificates: ['a' * 64],
      );
      VaultEntry? saved;
      await openEditor(
        tester,
        entry: original,
        onSaved: (value) => saved = value,
      );
      await tester.enterText(editorField('Title'), 'Updated account');
      await tester.ensureVisible(editorField('Email / username'));
      await tester.enterText(
        editorField('Email / username'),
        'after@example.test',
      );
      await editorTab(tester, 'Extra notes');
      expect(editorField('Password'), findsNothing);
      await tester.enterText(editorField('Extra notes'), 'Changed note');
      await editorTab(tester, '2FA');
      expect(
        tester
            .widget<TextField>(editorField('TOTP secret / otpauth URI'))
            .controller!
            .text,
        original.totp,
      );
      await editorTab(tester, 'Files (1)');
      expect(find.text('proof.txt'), findsOneWidget);
      await editorTab(tester, 'Autofill');
      expect(
        find.text('App verified. This login can be used for autofill.'),
        findsOneWidget,
      );
      await editorTab(tester, 'Login');
      expect(
        tester
            .widget<TextField>(editorField('Email / username'))
            .controller!
            .text,
        'after@example.test',
      );
      await tester.tap(find.text('Save item'));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(saved!.id, original.id);
      expect(saved!.title, 'Updated account');
      expect(saved!.username, 'after@example.test');
      expect(saved!.notes, 'Changed note');
      expect(saved!.password, original.password);
      expect(saved!.totp, original.totp);
      expect(saved!.favorite, isTrue);
      expect(saved!.attachments.single.id, original.attachments.single.id);
      expect(saved!.androidPackage, original.androidPackage);
      expect(saved!.androidCertificates, original.androidCertificates);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'short mobile editor reveals an invalid hidden 2FA field and can save',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      VaultEntry? saved;
      await openEditor(tester, onSaved: (value) => saved = value);
      await tester.ensureVisible(editorField('Title'));
      await tester.enterText(editorField('Title'), 'New account');
      await editorTab(tester, '2FA');
      await tester.ensureVisible(editorField('TOTP secret / otpauth URI'));
      await tester.enterText(
        editorField('TOTP secret / otpauth URI'),
        'invalid!',
      );
      await editorTab(tester, 'Files (0)');
      await tester.ensureVisible(find.text('Save item'));
      await tester.tap(find.text('Save item'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 2);
      expect(
        find.text('Use a valid Base32 TOTP secret or otpauth://totp URI.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(editorField('TOTP secret / otpauth URI'));
      await tester.enterText(
        editorField('TOTP secret / otpauth URI'),
        'JBSWY3DPEHPK3PXP',
      );
      await tester.ensureVisible(find.text('Save item'));
      await tester.tap(find.text('Save item'));
      await tester.pumpAndSettle();
      expect(saved?.title, 'New account');
      expect(saved?.totp, 'JBSWY3DPEHPK3PXP');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('authenticated recovery replaces corrupt storage without treating it as empty', () async {
    final store = AuditStore()..value = '{broken';
    final controller = VaultController(store), key = MasterKey.generate();
    final savedKey = key.display();
    try {
      final backup = VaultBundle(
        await VaultCodec().seal(
          VaultData(createdAt: DateTime.utc(2026), entries: []),
          key,
          vaultId: randomId(),
          revision: 1,
        ),
      ).serialize();
      await expectLater(
        controller.initialize(),
        throwsA(isA<VaultOpenFailure>()),
      );
      expect(controller.initialized, isFalse);
      expect(controller.encryptedBackup, '{broken');
      await expectLater(
        controller.restore(backup, MasterKey.generate()),
        throwsA(isA<VaultOpenFailure>()),
      );
      expect(store.value, '{broken');
      await controller.restore(backup, MasterKey.parse(savedKey));
      expect(controller.initialized, isTrue);
      expect(controller.unlocked, isTrue);
      expect(VaultBundle.parse(store.value!).header.revision, 2);
    } finally {
      controller.dispose();
      key.destroy();
    }
  });

  test('deletion history is retained when its limit is reached', () async {
    final store = AuditStore(), controller = VaultController(store);
    final key = MasterKey.generate(), savedKey = key.display(), id = randomId();
    final entry = VaultEntry(
      id: id,
      title: 'Keep me',
      updatedAt: DateTime.utc(2026),
    );
    try {
      final snapshot = VaultBundle(
        await VaultCodec().seal(
          VaultData(
            createdAt: DateTime.utc(2026),
            entries: [entry],
            tombstones: {
              for (var i = 0; i < maxItems; i++)
                i.toRadixString(16).padLeft(32, '0'): DateTime.utc(2026),
            },
          ),
          key,
          vaultId: randomId(),
          revision: 1,
        ),
      ).serialize();
      store.value = snapshot;
      await controller.initialize();
      await controller.unlock(MasterKey.parse(savedKey));
      await expectLater(controller.delete(id), throwsA(isA<FormatException>()));
      expect(controller.entries.single.id, id);
      expect(store.value, snapshot);
    } finally {
      controller.dispose();
      key.destroy();
    }
  });

  testWidgets('OTP widget reloads its secret and uses the configured period', (
    tester,
  ) async {
    final first = VaultEntry(
      id: randomId(),
      title: 'Account',
      totp: 'otpauth://totp/account?secret=JBSWY3DPEHPK3PXP&period=60',
      updatedAt: DateTime.utc(2026),
    );
    Future<void> show(VaultEntry entry) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OtpCard(entry: entry, copy: (_) async {}),
        ),
      ),
    );
    await show(first);
    await tester.pump(const Duration(milliseconds: 100));
    final progress = tester.widget<CircularProgressIndicator>(
      find.descendant(
        of: find.byType(OtpCard),
        matching: find.byType(CircularProgressIndicator),
      ),
    );
    final remaining = int.parse(
      tester
          .widget<Text>(find.textContaining(RegExp(r'^\d+s$')))
          .data!
          .replaceAll('s', ''),
    );
    expect(remaining, inInclusiveRange(1, 60));
    expect(find.textContaining(RegExp(r'^\d{6}$')), findsOneWidget);
    expect(progress.value, closeTo(remaining / 60, 0.001));
    await show(first.copyWith(totp: 'invalid!'));
    await tester.pump();
    expect(find.text('Invalid secret'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed automatic backup retries an unchanged vault', (
    tester,
  ) async {
    final store = AuditStore(),
        key = MasterKey.generate(),
        savedKey = key.display();
    final backups = RetryBackups();
    try {
      store.value = VaultBundle(
        await VaultCodec().seal(
          VaultData(
            createdAt: DateTime.utc(2026),
            entries: [],
            preferences: const VaultPreferences(
              backupEnabled: true,
              backupDirectory: '/synthetic',
            ),
          ),
          key,
          vaultId: randomId(),
          revision: 1,
        ),
      ).serialize();
      await tester.pumpWidget(
        SparVaultApp(store: store, integrations: backups),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, savedKey);
      await tester.tap(find.text('Unlock vault'));
      await tester.pumpAndSettle();
      expect(backups.writes, 1);
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(backups.writes, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      key.destroy();
    }
  });
}
