import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spar_vault/main.dart';
import 'package:vault_core/vault_core.dart';

class TestStore implements VaultStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String encrypted, {required String? expected}) async {
    if (value != expected) throw const ConcurrentVaultChange();
    value = encrypted;
  }
}

void main() {
  testWidgets('saved mobile login supports reveal, clipboard expiry and edit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final store = TestStore(), key = MasterKey.generate();
    final original = VaultEntry(
      id: 'a' * 32,
      title: 'Saved email',
      username: 'synthetic@example.test',
      password: 'Synthetic password 123!',
      updatedAt: DateTime.utc(2026),
    );
    store.value = await VaultCodec().seal(
      VaultData(createdAt: DateTime.utc(2026), entries: [original]),
      key,
      vaultId: 'b' * 32,
      revision: 1,
    );
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        return null;
      },
    );
    addTearDown(() {
      key.destroy();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(SparVaultApp(store: store));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, key.display());
    await tester.tap(find.text('Unlock vault'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(original.title),
      160,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.tap(find.text(original.title));
    await tester.pumpAndSettle();
    expect(find.text(original.password), findsNothing);
    await tester.tap(find.byTooltip('Copy Username'));
    await tester.pumpAndSettle();
    expect(clipboard, original.username);
    await tester.ensureVisible(find.text('Copy password'));
    await tester.tap(find.text('Copy password'));
    await tester.pumpAndSettle();
    expect(clipboard, original.password);
    expect(find.text(original.password), findsNothing);
    await tester.tap(find.byTooltip('Show password for 20 seconds'));
    await tester.pumpAndSettle();
    expect(find.text(original.password), findsOneWidget);
    await tester.pump(const Duration(seconds: 21));
    await tester.pumpAndSettle();
    expect(find.text(original.password), findsNothing);
    expect(clipboard, '');
    await tester.tap(find.text('Edit item'));
    await tester.pumpAndSettle();
    final passwordField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Password',
    );
    expect(
      tester.widget<TextField>(passwordField).controller!.text,
      original.password,
    );
    expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
    await tester.ensureVisible(passwordField);
    await tester.enterText(passwordField, 'Updated synthetic password 456!');
    await tester.ensureVisible(find.text('Save item'));
    await tester.tap(find.text('Save item'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(original.title),
      160,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.tap(find.text(original.title));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Copy password'));
    await tester.tap(find.text('Copy password'));
    await tester.pumpAndSettle();
    expect(clipboard, 'Updated synthetic password 456!');
    expect(find.text('Password history (1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'enrollment copy clears after 20 seconds and phone setup completes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = TestStore();
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(SparVaultApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a new vault'));
      await tester.pumpAndSettle();
      final keyText = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .firstWhere(
            (s) => RegExp(r'^(?:[A-F0-9]{8} ){7}[A-F0-9]{8}$').hasMatch(s),
          );
      await tester.ensureVisible(find.text('Copy master key'));
      await tester.tap(find.text('Copy master key'));
      await tester.pumpAndSettle();
      expect(
        clipboard == keyText,
        isTrue,
        reason: 'Clipboard must contain the complete enrollment key.',
      );
      await tester.pump(const Duration(seconds: 21));
      await tester.pumpAndSettle();
      expect(clipboard, '');
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), keyText);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create encrypted vault'));
      await tester.tap(find.text('Create encrypted vault'));
      await tester.pumpAndSettle();
      expect(find.text('Add login'), findsOneWidget);
      expect(store.value != null, isTrue);
      expect(find.text('Copy master key'), findsNothing);
      expect(find.text('Save key file'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a persisted vault opens, and idle locking removes rendered secrets',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = TestStore();
      final key = MasterKey.generate();
      final display = key.display();
      store.value = await VaultCodec().seal(
        VaultData(
          createdAt: DateTime.utc(2026),
          entries: [
            VaultEntry(
              id: 'a' * 32,
              title: 'Private email account',
              username: 'private@example.test',
              password: 'Never render me',
              updatedAt: DateTime.utc(2026),
            ),
          ],
        ),
        key,
        vaultId: 'b' * 32,
        revision: 1,
      );
      key.destroy();
      await tester.pumpWidget(SparVaultApp(store: store));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back.'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, display);
      await tester.tap(find.text('Unlock vault'));
      await tester.pumpAndSettle();
      expect(find.text('Private email account'), findsOneWidget);
      expect(find.text('Never render me'), findsNothing);
      await tester.pump(const Duration(seconds: 301));
      await tester.pumpAndSettle();
      expect(find.text('Private email account'), findsNothing);
      expect(find.text('private@example.test'), findsNothing);
      expect(find.text('Unlock vault'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'minimizing preserves session; elapsed background time locks on resume',
    (tester) async {
      final store = TestStore(), key = MasterKey.generate();
      final display = key.display();
      var clock = DateTime.utc(2026);
      store.value = await VaultCodec().seal(
        VaultData(
          createdAt: clock,
          entries: [
            VaultEntry(
              id: 'a' * 32,
              title: 'Visible secret title',
              updatedAt: clock,
            ),
          ],
        ),
        key,
        vaultId: 'b' * 32,
        revision: 1,
      );
      key.destroy();
      await tester.pumpWidget(SparVaultApp(store: store, now: () => clock));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, display);
      await tester.tap(find.text('Unlock vault'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      clock = clock.add(const Duration(seconds: 30));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Visible secret title'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      clock = clock.add(const Duration(minutes: 6));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Visible secret title'), findsNothing);
      expect(find.text('Unlock vault'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('pagination and search reset the displayed page', (tester) async {
    final store = TestStore(), key = MasterKey.generate();
    final display = key.display();
    store.value = await VaultCodec().seal(
      VaultData(
        createdAt: DateTime.utc(2026),
        entries: List.generate(
          35,
          (i) => VaultEntry(
            id: i.toRadixString(16).padLeft(32, '0'),
            title: 'Entry ${i.toString().padLeft(2, '0')}',
            updatedAt: DateTime.utc(2026),
          ),
        ),
      ),
      key,
      vaultId: 'b' * 32,
      revision: 1,
    );
    key.destroy();
    await tester.pumpWidget(SparVaultApp(store: store));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, display);
    await tester.tap(find.text('Unlock vault'));
    await tester.pumpAndSettle();
    expect(find.text('Entry 34'), findsNothing);
    await tester.scrollUntilVisible(
      find.byTooltip('Next page'),
      600,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 / 2 • 35 items'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Entry 00');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Entry 00'), findsOneWidget);
    expect(find.text('Page 1 / 1 • 1 items'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'late interaction cannot revive an expired session or show stale details',
    (tester) async {
      final store = TestStore(), key = MasterKey.generate();
      final display = key.display();
      var clock = DateTime.utc(2026);
      store.value = await VaultCodec().seal(
        VaultData(
          createdAt: clock,
          entries: [
            VaultEntry(
              id: 'a' * 32,
              title: 'Expired item',
              notes: 'Sensitive note',
              updatedAt: clock,
            ),
          ],
        ),
        key,
        vaultId: 'b' * 32,
        revision: 1,
      );
      key.destroy();
      await tester.pumpWidget(SparVaultApp(store: store, now: () => clock));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, display);
      await tester.tap(find.text('Unlock vault'));
      await tester.pumpAndSettle();
      clock = clock.add(const Duration(minutes: 6));
      await tester.tap(find.text('Expired item'));
      await tester.pumpAndSettle();
      expect(find.text('Sensitive note'), findsNothing);
      expect(find.text('Expired item'), findsNothing);
      expect(find.text('Unlock vault'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
