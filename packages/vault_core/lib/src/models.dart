import 'dart:convert';

const maxItems = 2000;
const maxPlaintextBytes = 16 * 1024 * 1024;
const maxEnvelopeBytes = 32 * 1024 * 1024;
const maxAttachmentBytes = 2 * 1024 * 1024;
const maxTotalAttachmentBytes = 8 * 1024 * 1024;

String checkedString(Object? value, int max, {bool nonEmpty = false}) {
  if (value is! String || value.length > max || (nonEmpty && value.isEmpty)) {
    throw const FormatException('Invalid vault field.');
  }
  return value;
}

void checkId(String id) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
    throw const FormatException('Invalid identifier.');
  }
}

DateTime checkedDate(Object? value) {
  final date = DateTime.tryParse(checkedString(value, 40));
  if (date == null || !date.isUtc) {
    throw const FormatException('Invalid timestamp.');
  }
  return date;
}

void checkFields(Map<String, dynamic> data, Set<String> fields) {
  if (data.keys.toSet().difference(fields).isNotEmpty ||
      data.length != fields.length) {
    throw const FormatException('Unsupported vault schema.');
  }
}

List<String> certificateList(Object? value) {
  if (value is! List || value.length > 8) {
    throw const FormatException('Invalid certificate list.');
  }
  return List.unmodifiable(value.map((v) {
    final s = checkedString(v, 64);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(s)) {
      throw const FormatException('Invalid certificate.');
    }
    return s;
  }));
}

enum EntryKind { login, note }

class PasswordVersion {
  PasswordVersion(this.password, this.changedAt) {
    checkedString(password, 4096);
    if (!changedAt.isUtc) throw const FormatException('Use UTC timestamps.');
  }
  final String password;
  final DateTime changedAt;
  Map<String, Object> toJson() =>
      {'password': password, 'changedAt': changedAt.toIso8601String()};
  factory PasswordVersion.fromJson(Map<String, dynamic> m) {
    checkFields(m, {'password', 'changedAt'});
    return PasswordVersion(
        checkedString(m['password'], 4096), checkedDate(m['changedAt']));
  }
}

class VaultAttachment {
  VaultAttachment(
      {required this.id, required this.name, required this.base64Bytes}) {
    checkId(id);
    checkedString(name, 200, nonEmpty: true);
    if (name == '.' ||
        name == '..' ||
        RegExp(r'[/\\\x00-\x1f]').hasMatch(name)) {
      throw const FormatException('Unsafe attachment filename.');
    }
    checkedString(base64Bytes, ((maxAttachmentBytes + 2) ~/ 3) * 4);
    final bytes = base64Decode(base64Bytes);
    try {
      if (bytes.length > maxAttachmentBytes ||
          base64Encode(bytes) != base64Bytes) {
        throw const FormatException('Attachment exceeds the limit.');
      }
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }
  final String id, name, base64Bytes;
  int get byteLength =>
      (base64Bytes.length ~/ 4) * 3 -
      (base64Bytes.endsWith('==')
          ? 2
          : base64Bytes.endsWith('=')
              ? 1
              : 0);
  Map<String, Object> toJson() =>
      {'id': id, 'name': name, 'bytes': base64Bytes};
  factory VaultAttachment.fromJson(Map<String, dynamic> m) {
    checkFields(m, {'id', 'name', 'bytes'});
    return VaultAttachment(
        id: checkedString(m['id'], 32),
        name: checkedString(m['name'], 200),
        base64Bytes:
            checkedString(m['bytes'], ((maxAttachmentBytes + 2) ~/ 3) * 4));
  }
}

class VaultEntry {
  VaultEntry(
      {required this.id,
      required this.title,
      this.username = '',
      this.password = '',
      this.url = '',
      this.notes = '',
      this.favorite = false,
      this.kind = EntryKind.login,
      required this.updatedAt,
      this.totp = '',
      List<PasswordVersion> history = const [],
      List<VaultAttachment> attachments = const [],
      this.androidPackage = '',
      List<String> androidCertificates = const []})
      : history = List.unmodifiable(history),
        attachments = List.unmodifiable(attachments),
        androidCertificates = List.unmodifiable(androidCertificates) {
    checkId(id);
    checkedString(title, 200, nonEmpty: true);
    checkedString(username, 1000);
    checkedString(password, 4096);
    checkedString(url, 2000);
    checkedString(notes, 20000);
    checkedString(totp, 2048);
    checkedString(androidPackage, 200);
    if (androidPackage.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$')
            .hasMatch(androidPackage)) {
      throw const FormatException('Invalid Android package.');
    }
    certificateList(androidCertificates);
    if (!updatedAt.isUtc ||
        history.length > 10 ||
        attachments.length > 10 ||
        attachments.map((a) => a.id).toSet().length != attachments.length) {
      throw const FormatException('Invalid entry contents.');
    }
  }
  final String id, title, username, password, url, notes, totp, androidPackage;
  final List<String> androidCertificates;
  final List<PasswordVersion> history;
  final List<VaultAttachment> attachments;
  final bool favorite;
  final EntryKind kind;
  final DateTime updatedAt;
  VaultEntry copyWith(
          {String? title,
          String? username,
          String? password,
          String? url,
          String? notes,
          String? totp,
          bool? favorite,
          EntryKind? kind,
          DateTime? updatedAt,
          List<PasswordVersion>? history,
          List<VaultAttachment>? attachments,
          String? androidPackage,
          List<String>? androidCertificates}) =>
      VaultEntry(
          id: id,
          title: title ?? this.title,
          username: username ?? this.username,
          password: password ?? this.password,
          url: url ?? this.url,
          notes: notes ?? this.notes,
          totp: totp ?? this.totp,
          favorite: favorite ?? this.favorite,
          kind: kind ?? this.kind,
          updatedAt: updatedAt ?? this.updatedAt,
          history: history ?? this.history,
          attachments: attachments ?? this.attachments,
          androidPackage: androidPackage ?? this.androidPackage,
          androidCertificates: androidCertificates ?? this.androidCertificates);
  Map<String, Object> toJson() => {
        'id': id,
        'title': title,
        'username': username,
        'password': password,
        'url': url,
        'notes': notes,
        'favorite': favorite,
        'kind': kind.name,
        'updatedAt': updatedAt.toIso8601String(),
        'totp': totp,
        'history': history.map((v) => v.toJson()).toList(),
        'attachments': attachments.map((a) => a.toJson()).toList(),
        'androidPackage': androidPackage,
        'androidCertificates': androidCertificates
      };
  factory VaultEntry.fromJson(Map<String, dynamic> m) {
    const oldFields = {
      'id',
      'title',
      'username',
      'password',
      'url',
      'notes',
      'favorite',
      'kind',
      'updatedAt'
    };
    final legacy = m.length == 9;
    checkFields(
        m,
        legacy
            ? oldFields
            : {
                ...oldFields,
                'totp',
                'history',
                'attachments',
                'androidPackage',
                'androidCertificates'
              });
    if (m['favorite'] is! bool) throw const FormatException('Invalid entry.');
    final kind = switch (m['kind']) {
      'login' => EntryKind.login,
      'note' => EntryKind.note,
      _ => throw const FormatException('Invalid entry type.')
    };
    List<T> list<T>(
        String name, int limit, T Function(Map<String, dynamic>) parse) {
      final values = legacy ? const [] : m[name];
      if (values is! List || values.length > limit) {
        throw const FormatException('Invalid entry list.');
      }
      return values.map((v) {
        if (v is! Map<String, dynamic>) {
          throw const FormatException('Invalid entry item.');
        }
        return parse(v);
      }).toList();
    }

    return VaultEntry(
        id: checkedString(m['id'], 32),
        title: checkedString(m['title'], 200, nonEmpty: true),
        username: checkedString(m['username'], 1000),
        password: checkedString(m['password'], 4096),
        url: checkedString(m['url'], 2000),
        notes: checkedString(m['notes'], 20000),
        favorite: m['favorite'] as bool,
        kind: kind,
        updatedAt: checkedDate(m['updatedAt']),
        totp: legacy ? '' : checkedString(m['totp'], 2048),
        history: list('history', 10, PasswordVersion.fromJson),
        attachments: list('attachments', 10, VaultAttachment.fromJson),
        androidPackage: legacy ? '' : checkedString(m['androidPackage'], 200),
        androidCertificates:
            legacy ? [] : certificateList(m['androidCertificates']));
  }
  @override
  String toString() => 'VaultEntry(<redacted>)';
}

class VaultPreferences {
  const VaultPreferences(
      {this.idleMinutes = 5,
      this.lockOnBackground = false,
      this.pageSize = 20,
      this.backupEnabled = false,
      this.backupDirectory = '',
      this.backupReminderDays = 7,
      this.lastBackupAt,
      this.autofillEnabled = false,
      this.chromeCertificates = const [],
      this.desktopExtensionId = ''});
  final int idleMinutes, pageSize, backupReminderDays;
  final bool lockOnBackground, backupEnabled, autofillEnabled;
  final String backupDirectory, desktopExtensionId;
  final DateTime? lastBackupAt;
  final List<String> chromeCertificates;
  VaultPreferences copyWith(
          {int? idleMinutes,
          bool? lockOnBackground,
          int? pageSize,
          bool? backupEnabled,
          String? backupDirectory,
          int? backupReminderDays,
          DateTime? lastBackupAt,
          bool? autofillEnabled,
          List<String>? chromeCertificates,
          String? desktopExtensionId}) =>
      VaultPreferences(
          idleMinutes: idleMinutes ?? this.idleMinutes,
          lockOnBackground: lockOnBackground ?? this.lockOnBackground,
          pageSize: pageSize ?? this.pageSize,
          backupEnabled: backupEnabled ?? this.backupEnabled,
          backupDirectory: backupDirectory ?? this.backupDirectory,
          backupReminderDays: backupReminderDays ?? this.backupReminderDays,
          lastBackupAt: lastBackupAt ?? this.lastBackupAt,
          autofillEnabled: autofillEnabled ?? this.autofillEnabled,
          chromeCertificates: chromeCertificates ?? this.chromeCertificates,
          desktopExtensionId: desktopExtensionId ?? this.desktopExtensionId);
  Map<String, Object?> toJson() => {
        'idleMinutes': idleMinutes,
        'lockOnBackground': lockOnBackground,
        'pageSize': pageSize,
        'backupEnabled': backupEnabled,
        'backupDirectory': backupDirectory,
        'backupReminderDays': backupReminderDays,
        'lastBackupAt': lastBackupAt?.toIso8601String(),
        'autofillEnabled': autofillEnabled,
        'chromeCertificates': chromeCertificates,
        'desktopExtensionId': desktopExtensionId
      };
  factory VaultPreferences.fromJson(Map<String, dynamic> m) {
    checkFields(m, {
      'idleMinutes',
      'lockOnBackground',
      'pageSize',
      'backupEnabled',
      'backupDirectory',
      'backupReminderDays',
      'lastBackupAt',
      'autofillEnabled',
      'chromeCertificates',
      'desktopExtensionId'
    });
    if (checkedString(m['desktopExtensionId'], 32).isNotEmpty &&
        !RegExp(r'^[a-p]{32}$').hasMatch(m['desktopExtensionId'] as String)) {
      throw const FormatException('Use the 32-letter browser extension ID.');
    }
    if (![1, 2, 5, 10, 15, 30].contains(m['idleMinutes']) ||
        ![10, 20, 50].contains(m['pageSize']) ||
        ![1, 3, 7, 14, 30].contains(m['backupReminderDays']) ||
        m['lockOnBackground'] is! bool ||
        m['backupEnabled'] is! bool ||
        m['autofillEnabled'] is! bool) {
      throw const FormatException('Invalid preferences.');
    }
    return VaultPreferences(
        idleMinutes: m['idleMinutes'] as int,
        lockOnBackground: m['lockOnBackground'] as bool,
        pageSize: m['pageSize'] as int,
        backupEnabled: m['backupEnabled'] as bool,
        backupDirectory: checkedString(m['backupDirectory'], 4096),
        backupReminderDays: m['backupReminderDays'] as int,
        lastBackupAt:
            m['lastBackupAt'] == null ? null : checkedDate(m['lastBackupAt']),
        autofillEnabled: m['autofillEnabled'] as bool,
        chromeCertificates: certificateList(m['chromeCertificates']),
        desktopExtensionId: checkedString(m['desktopExtensionId'], 32));
  }
}

class VaultData {
  VaultData(
      {required this.createdAt,
      required List<VaultEntry> entries,
      this.preferences = const VaultPreferences(),
      Map<String, DateTime> tombstones = const {}})
      : entries = List.unmodifiable(entries),
        tombstones = Map.unmodifiable(tombstones) {
    if (!createdAt.isUtc ||
        entries.length > maxItems ||
        tombstones.length > maxItems ||
        entries.map((e) => e.id).toSet().length != entries.length) {
      throw const FormatException('Invalid vault contents.');
    }
    var total = 0;
    for (final e in entries) {
      for (final a in e.attachments) {
        total += a.byteLength;
      }
    }
    if (total > maxTotalAttachmentBytes) {
      throw const FormatException('Attachments exceed the vault limit.');
    }
    for (final t in tombstones.entries) {
      checkId(t.key);
      if (!t.value.isUtc || entries.any((e) => e.id == t.key)) {
        throw const FormatException('Invalid deletion record.');
      }
    }
    VaultPreferences.fromJson(preferences.toJson());
  }
  final DateTime createdAt;
  final List<VaultEntry> entries;
  final VaultPreferences preferences;
  final Map<String, DateTime> tombstones;
  Map<String, Object> toJson() => {
        'schema': 2,
        'createdAt': createdAt.toIso8601String(),
        'entries': entries.map((e) => e.toJson()).toList(),
        'preferences': preferences.toJson(),
        'tombstones':
            tombstones.map((id, date) => MapEntry(id, date.toIso8601String()))
      };
  factory VaultData.fromJson(Map<String, dynamic> m) {
    final legacy = m['schema'] == 1;
    checkFields(
        m,
        legacy
            ? {'schema', 'createdAt', 'entries'}
            : {'schema', 'createdAt', 'entries', 'preferences', 'tombstones'});
    if ((!legacy && m['schema'] != 2) ||
        m['entries'] is! List ||
        (m['entries'] as List).length > maxItems) {
      throw const FormatException('Invalid vault schema.');
    }
    final tombstones = <String, DateTime>{};
    if (!legacy) {
      if (m['preferences'] is! Map<String, dynamic> ||
          m['tombstones'] is! Map<String, dynamic> ||
          (m['tombstones'] as Map).length > maxItems) {
        throw const FormatException('Invalid vault settings.');
      }
      (m['tombstones'] as Map<String, dynamic>)
          .forEach((k, v) => tombstones[k] = checkedDate(v));
    }
    return VaultData(
        createdAt: checkedDate(m['createdAt']),
        entries: (m['entries'] as List).map((e) {
          if (e is! Map<String, dynamic>) {
            throw const FormatException('Invalid entry.');
          }
          return VaultEntry.fromJson(e);
        }).toList(),
        preferences: legacy
            ? const VaultPreferences()
            : VaultPreferences.fromJson(
                m['preferences'] as Map<String, dynamic>),
        tombstones: tombstones);
  }
  @override
  String toString() => 'VaultData(<redacted>)';
}
