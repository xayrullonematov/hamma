// ignore_for_file: deprecated_member_use

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Per-plugin namespaced secure-storage backend.
///
/// The store sits behind [HammaApi.readConfig] / [writeConfig] /
/// [deleteConfig]; plugins never see the raw [FlutterSecureStorage]
/// handle. Keys are written as `plugin__<pluginId>__<key>`, which:
///
///   * scopes every plugin to its own namespace — one plugin can
///     never read another's secrets, even though they share the
///     same backing keystore;
///   * makes plugin keys easy to grep / wipe wholesale (`plugin__`
///     prefix) when a user uninstalls / disables an extension; and
///   * keeps plugin keys distinguishable from the app's own keys
///     (`app_lock_pin`, `saved_servers`, …) so a future audit script
///     can enumerate "all plugin-owned secrets" in one pass.
///
/// The double underscore separator is intentional — it ensures that
/// even a plugin whose id contains an underscore (`my_plugin`) can
/// never collide with another plugin id and key combo.
class PluginConfigStore {
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  const PluginConfigStore({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(aOptions: _androidOptions);

  final FlutterSecureStorage _secureStorage;

  static const _prefix = 'plugin__';

  String _key(String pluginId, String key) => '$_prefix${pluginId}__$key';

  Future<String?> read(String pluginId, String key) async {
    return _secureStorage.read(key: _key(pluginId, key));
  }

  Future<void> write(String pluginId, String key, String value) async {
    await _secureStorage.write(key: _key(pluginId, key), value: value);
  }

  Future<void> delete(String pluginId, String key) async {
    await _secureStorage.delete(key: _key(pluginId, key));
  }
}
