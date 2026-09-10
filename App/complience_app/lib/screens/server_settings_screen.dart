import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/backend_api.dart';
import '../services/ocr_store.dart';
import '../services/server_config.dart';
import '../services/sync_service.dart';

/// Server Settings — one-time officer setup so scans sync to the server (D)
/// and the dashboard (E) + archival PDFs (F) stay populated.
///
/// * Server URL: baked in via `--dart-define=API_BASE_URL=` for release
///   builds; this screen only shows when no compile-time URL is set, or to
///   point at a local dev server (`http://10.0.2.2:5000` from the emulator).
/// * Sign in with the officer account seeded on the server
///   (`officer@gov.in`). Token kept in secure storage (12h expiry).
/// * "Sync now" uploads every unsynced local scan with backoff.
/// * Without sign-in the app keeps working fully offline — rows just queue.
class ServerSettingsScreen extends StatefulWidget {
  const ServerSettingsScreen({super.key});

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  final _urlController = TextEditingController();
  final _emailController = TextEditingController(text: 'officer@gov.in');
  final _passwordController = TextEditingController();
  String _baseUrl = '';
  String? _userLabel;
  bool _signedIn = false;
  bool _busy = false;
  bool _syncing = false;
  int _unsynced = 0;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final base = await ServerConfig.instance.baseUrl();
    final token = await ServerConfig.instance.token();
    final userJson = await ServerConfig.instance.userJson();
    String? label;
    if (userJson != null && userJson.isNotEmpty) {
      try {
        final u = jsonDecode(userJson) as Map;
        label = '${u['name'] ?? u['email'] ?? ''} · ${u['role'] ?? ''}';
      } catch (_) {}
    }
    final unsynced = await OcrStore.instance.countUnsyncedScans().catchError((_) => 0);
    if (!mounted) return;
    setState(() {
      _baseUrl = base;
      _urlController.text = base;
      _signedIn = token != null && token.isNotEmpty;
      _userLabel = label;
      _unsynced = unsynced;
    });
  }

  Future<void> _saveUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    await ServerConfig.instance.setBaseUrlOverride(url);
    if (!mounted) return;
    setState(() {
      _baseUrl = url;
      _status = 'Server set to $url';
    });
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await _saveUrl();
      final res = await BackendApi.instance.login(
        email: _emailController.text,
        password: _passwordController.text,
      );
      final user = res['user'];
      if (!mounted) return;
      setState(() {
        _signedIn = true;
        _userLabel = user is Map ? '${user['name']} · ${user['role']}' : 'Signed in';
        _status = 'Signed in — queued scans will now upload.';
      });
      await _syncNow();
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    await BackendApi.instance.logout();
    if (!mounted) return;
    setState(() {
      _signedIn = false;
      _userLabel = null;
      _status = 'Signed out. Scanning stays offline; uploads paused.';
    });
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _status = null;
    });
    try {
      final (uploaded, remaining) = await SyncService.instance.syncNow();
      if (!mounted) return;
      // A concurrent background enqueue returns (0, 0) — don't claim
      // "already synced" when a pass is still running elsewhere.
      final err = SyncService.instance.lastError;
      final needsLogin = SyncService.instance.lastErrorIsAuth;
      final remainingNow =
          await OcrStore.instance.countUnsyncedScans().catchError((_) => remaining);
      setState(() {
        _unsynced = remainingNow;
        if (needsLogin) {
          _signedIn = false;
          _userLabel = null;
        }
        if (uploaded == 0 && remainingNow == 0) {
          _status = 'Everything is already synced.';
        } else if (uploaded > 0 && remainingNow == 0) {
          _status = 'Uploaded $uploaded scan(s). All synced.';
        } else if (uploaded > 0) {
          _status = 'Uploaded $uploaded scan(s). $remainingNow still queued.'
              '${err != null ? '\nNote: $err' : ''}';
        } else {
          _status = remainingNow > 0
              ? 'Nothing uploaded. $remainingNow still queued.'
                  '${err != null ? '\n$err' : ''}'
              : 'Sync finished.';
        }
      });
    } on BackendException catch (e) {
      // Auth expiry aborts the batch — flip UI to signed-out immediately.
      if (!mounted) return;
      final remainingNow =
          await OcrStore.instance.countUnsyncedScans().catchError((_) => _unsynced);
      setState(() {
        _unsynced = remainingNow;
        if (e.statusCode == 401) {
          _signedIn = false;
          _userLabel = null;
          _status = 'Session expired — please sign in again. '
              '$remainingNow scan(s) stay queued on this device.';
        } else {
          _status = 'Sync failed: ${e.message} '
              '($remainingNow still queued).';
        }
      });
    } catch (e) {
      if (!mounted) return;
      final err = SyncService.instance.lastError;
      setState(() => _status =
          'Sync failed: ${err ?? e} ($_unsynced still queued).');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server & sync')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Sign in once — every scan then copies itself to the server '
            'in the background. Offline scanning always works.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Server URL',
              hintText: 'https://your-api.onrender.com',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : _saveUrl,
              child: const Text('Save server URL'),
            ),
          ),
          const Divider(height: 24),
          if (_signedIn) ...[
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(_userLabel ?? 'Signed in'),
              subtitle: Text('Server: $_baseUrl'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _syncing ? null : _syncNow,
                  icon: _syncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined),
                  label: Text(_syncing ? 'Syncing…' : 'Sync now ($_unsynced queued)'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: _busy ? null : _logout,
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ] else ...[
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Officer email',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              onSubmitted: (_) => _login(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _login,
              icon: const Icon(Icons.login_outlined),
              label: Text(_busy ? 'Signing in…' : 'Sign in & sync'),
            ),
            const SizedBox(height: 8),
            Text(
              'Requests will go to:\n$_baseUrl',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '$_unsynced scan(s) waiting on this device.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_status != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_status!),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Dashboard: $_baseUrl/dashboard\n'
            'The web register shows every synced scan, top violations, '
            'archival PDFs and the Excel sheet.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
