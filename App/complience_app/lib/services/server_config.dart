library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the D/E/F server lives and who we are to it.
///
/// Resolution order for the base URL:
/// 1. officer override typed in Server Settings (stored securely on-device) —
///    what you type always wins, so a changed server address never needs a
///    reinstall,
/// 2. `--dart-define=API_BASE_URL=https://<host>` (build-time default for
///    release/demo APKs),
/// 3. `http://10.0.2.2:5000` (handy for `flutter run` against a local
///    `npm run dev`).
///
/// The auth token (JWT, 12h expiry) is kept in secure storage; photo paths
/// and report JSON never leave the device except via [BackendApi.uploadScan].

class ServerConfig {
  ServerConfig._();
  static final ServerConfig instance = ServerConfig._();

  static const _tokenKey = 'server_jwt';
  static const _baseUrlKey = 'server_base_url_override';
  static const _userKey = 'server_user_json';

  static const _storage = FlutterSecureStorage();
  String? _memToken;
  String? _memBaseUrl;
  String? _memUser;

  /// Compile-time default. Pass at build time:
  /// `flutter build apk --dart-define=API_BASE_URL=https://<host>`
  static const String compileTimeBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );

  Future<String> baseUrl() async {
    final override = await _read(_baseUrlKey, (v) => _memBaseUrl = v, () => _memBaseUrl);
    if (override != null && override.trim().isNotEmpty) {
      return _strip(override.trim());
    }
    if (compileTimeBaseUrl.isNotEmpty) return _strip(compileTimeBaseUrl);
    return 'http://10.0.2.2:5000';
  }

  Future<void> setBaseUrlOverride(String url) async {
    await _write(_baseUrlKey, url.trim(), (v) => _memBaseUrl = v);
  }

  Future<String?> token() => _read(_tokenKey, (v) => _memToken = v, () => _memToken);
  Future<void> setToken(String t) => _write(_tokenKey, t, (v) => _memToken = v);
  Future<void> clearToken() async {
    await _delete(_tokenKey, () => _memToken = null);
    await _delete(_userKey, () => _memUser = null);
  }

  Future<String?> userJson() => _read(_userKey, (v) => _memUser = v, () => _memUser);
  Future<void> setUserJson(String j) => _write(_userKey, j, (v) => _memUser = v);

  static String _strip(String u) => u.replaceAll(RegExp(r'/+$'), '');

  Future<String?> _read(
    String key,
    void Function(String?) memo,
    String? Function() mem,
  ) async {
    try {
      final v = await _storage.read(key: key);
      memo(v);
      return v;
    } catch (_) {
      return mem();
    }
  }

  Future<void> _write(String key, String value, void Function(String?) memo) async {
    memo(value);
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {}
  }

  Future<void> _delete(String key, void Function() memo) async {
    memo();
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }
}
