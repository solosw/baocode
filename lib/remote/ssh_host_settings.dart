import 'dart:async';

import 'package:bao_remote/client.dart';
import 'package:flutter/foundation.dart';

import '../models/secret_store.dart';
import '../settings/user_settings.dart';

/// How a host saved in settings signs in: a password, or a private key.
enum SshAuthKind { password, key }

/// One host the app keeps itself, besides `~/.ssh/config`. The password
/// lives in the keychain ([SshHostSettings.passwordId]); the rest is in
/// settings.json.
class SshSavedHost {
  const SshSavedHost({
    required this.host,
    this.user = '',
    this.port,
    this.auth = SshAuthKind.password,
    this.identityFile = '',
    this.hasPassword = false,
  });

  /// `host` or `host:port` as the connect box names it.
  final String host;
  final String user;
  final int? port;
  final SshAuthKind auth;
  final String identityFile;

  /// Whether a password is kept for [host]. The secret itself is not here.
  final bool hasPassword;

  /// What the connect box and [SshHost] use.
  String get target {
    final base = host.trim();
    final port = this.port;
    if (port == null || port <= 0 || base.contains(':')) return base;
    return '$base:$port';
  }

  SshSavedHost copyWith({
    String? host,
    String? user,
    int? port,
    bool clearPort = false,
    SshAuthKind? auth,
    String? identityFile,
    bool? hasPassword,
  }) => SshSavedHost(
    host: host ?? this.host,
    user: user ?? this.user,
    port: clearPort ? null : port ?? this.port,
    auth: auth ?? this.auth,
    identityFile: identityFile ?? this.identityFile,
    hasPassword: hasPassword ?? this.hasPassword,
  );

  Map<String, Object?> toJson() => {
    'host': host,
    'user': user,
    if (port != null) 'port': port,
    'auth': auth.name,
    if (identityFile.isNotEmpty) 'identityFile': identityFile,
  };

  static SshSavedHost? fromJson(Object? raw, {bool hasPassword = false}) {
    if (raw is! Map) return null;
    final host = raw['host'];
    if (host is! String || host.trim().isEmpty) return null;
    final port = raw['port'];
    return SshSavedHost(
      host: host.trim(),
      user: raw['user'] is String ? (raw['user'] as String).trim() : '',
      port: port is int ? port : int.tryParse('$port'),
      auth: raw['auth'] == 'key' ? SshAuthKind.key : SshAuthKind.password,
      identityFile: raw['identityFile'] is String
          ? (raw['identityFile'] as String).trim()
          : '',
      hasPassword: hasPassword,
    );
  }
}

/// The app's own SSH hosts (`remote.ssh.hosts` in settings.json). Passwords
/// are kept by [secrets], never in the file. `~/.ssh/config` is still read
/// for hosts that are not listed here.
class SshHostSettings extends ChangeNotifier {
  SshHostSettings({UserSettings? settings, SecretStore? secrets})
    : _settings = settings,
      _secrets = secrets;

  static const settingKey = 'remote.ssh.hosts';

  /// The app's, once settings exist. Tests set their own.
  static SshHostSettings instance = SshHostSettings();

  final UserSettings? _settings;
  final SecretStore? _secrets;
  SecretStore get secrets => _secrets ?? SecretStore.instance;

  List<SshSavedHost> _hosts = const [];

  List<SshSavedHost> get hosts => List.unmodifiable(_hosts);

  /// Hosts the connect box should offer, in saved order.
  List<String> get targets => [
    for (final host in _hosts)
      if (host.target.isNotEmpty) host.target,
  ];

  /// The saved host named [text] (`dev`, `me@dev`, `dev:2222`).
  SshSavedHost? match(String text) {
    final parsed = SshTarget.parse(text.trim());
    for (final host in _hosts) {
      if (host.host == parsed.destination ||
          host.host == text.trim() ||
          host.target == text.trim()) {
        return host;
      }
    }
    return null;
  }

  /// `ssh` options for [target], or none when the host is not saved here.
  SshConnectOptions? optionsFor(SshTarget target) {
    final host = match(target.text);
    if (host == null) return null;
    return SshConnectOptions(
      user: host.user.isEmpty ? null : host.user,
      port: host.port,
      identityFile: host.auth == SshAuthKind.key && host.identityFile.isNotEmpty
          ? host.identityFile
          : null,
    );
  }

  static String passwordId(String host) => 'ssh-host:${host.trim()}';

  Future<void> load() async {
    final raw = _settings?[settingKey];
    final list = raw is List ? raw : const [];
    final hosts = <SshSavedHost>[];
    for (final item in list) {
      final host = SshSavedHost.fromJson(item);
      if (host == null) continue;
      var hasPassword = false;
      try {
        hasPassword = (await secrets.read(passwordId(host.host))) != null;
      } on SecretStoreException {
        hasPassword = false;
      }
      hosts.add(host.copyWith(hasPassword: hasPassword));
    }
    _hosts = hosts;
    notifyListeners();
  }

  Future<String?> passwordOf(String host) async {
    try {
      return await secrets.read(passwordId(host));
    } on SecretStoreException {
      return null;
    }
  }

  /// Replaces the list. [passwords] sets or clears a host's secret (`null`
  /// leaves it, empty deletes it).
  Future<void> save(
    List<SshSavedHost> hosts, {
    Map<String, String?> passwords = const {},
  }) async {
    for (final entry in passwords.entries) {
      final id = passwordId(entry.key);
      final value = entry.value;
      try {
        if (value == null || value.isEmpty) {
          await secrets.delete(id);
        } else {
          await secrets.write(id, value);
        }
      } on SecretStoreException {
        // The host is still kept; the password can be typed at connect.
      }
    }
    final next = <SshSavedHost>[];
    for (final host in hosts) {
      // A blank row is the editor shown after Add. It stays on screen until
      // a host name is typed; it is not written to settings.json.
      if (host.host.trim().isEmpty) {
        next.add(host);
        continue;
      }
      final changed = passwords.containsKey(host.host);
      final hasPassword = changed
          ? (passwords[host.host]?.isNotEmpty ?? false)
          : host.hasPassword;
      next.add(host.copyWith(host: host.host.trim(), hasPassword: hasPassword));
    }
    _hosts = next;
    notifyListeners();
    try {
      await _settings?.update(settingKey, [
        for (final host in next)
          if (host.host.trim().isNotEmpty) host.toJson(),
      ]);
    } on Object catch (error) {
      debugPrint('ssh hosts not kept: $error');
    }
  }
}
