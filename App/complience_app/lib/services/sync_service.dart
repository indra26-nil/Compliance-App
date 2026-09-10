library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'backend_api.dart';
import 'ocr_store.dart';
import 'server_config.dart';

/// Offline-first upload queue (D).
///
/// Rules:
/// * The local `product_scans` row is ALWAYS the source of truth — the
///   report card never waits for upload.
/// * [enqueue] is fire-and-forget from `ScanPipeline.checkAndSave`.
/// * Uploads run only when a token exists and the device is online
///   (`connectivity_plus`); failures keep the row queued and retry on the
///   next enqueue / app start / manual "Sync now" (no long in-batch sleeps,
///   so the UI never hangs on "Syncing…").
/// * Text-only sync: report JSON + OCR text go up; photos stay on-device.
///   (Photo evidence upload is a server-side switch away when needed —
///   pass paths to [BackendApi.uploadScan].)

class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  bool _running = false;

  /// Consecutive failed upload attempts (reset on any success). Used to
  /// space out automatic background retries — the manual "Sync now" batch
  /// itself never sleeps more than ~1s per row so the spinner can't hang.
  int _failures = 0;

  /// Human-readable reason the last [syncNow] stopped early (auth expired,
  /// server down, validation…). UI shows this instead of spinning forever.
  /// Null means the last pass had no transport-level failure.
  String? lastError;

  /// True when [lastError] is an auth failure — the officer must sign in
  /// again; retrying with the same token will never succeed.
  bool lastErrorIsAuth = false;

  /// Consecutive failed upload attempts (reset on any success). UI /
  /// diagnostics can read this; background [enqueue] callers use it to
  /// decide when to back off between passes.
  int get consecutiveFailures => _failures;

  /// Queue one local scan for upload (or nudge the queue). Never throws.
  void enqueue([int? localId]) {
    unawaited(syncNow());
  }

  /// Upload all unsynced rows. Returns (uploaded, remaining).
  ///
  /// Never spins forever: auth failures abort the batch immediately (and
  /// rethrow as [BackendException] so the caller can prompt sign-in),
  /// per-row transport failures get only a short pause (not exponential
  /// minutes), and [lastError]/[lastErrorIsAuth] always describe the stop
  /// reason. Rows that fail stay `synced = 0` and are retried next time.
  Future<(int, int)> syncNow() async {
    if (_running) return (0, 0);
    _running = true;
    var uploaded = 0;
    lastError = null;
    lastErrorIsAuth = false;
    try {
      final token = await ServerConfig.instance.token();
      if (token == null || token.isEmpty) {
        lastError = 'Not signed in — sign in under Server & sync.';
        lastErrorIsAuth = true;
        return (0, 0);
      }
      if (!await _online()) {
        lastError = 'Offline — queued scans will upload when online.';
        return (0, 0);
      }

      final pending =
          await OcrStore.instance.listUnsyncedScans(limit: 50);
      for (final record in pending) {
        if (!await _online()) {
          lastError ??= 'Went offline — remaining scans stay queued.';
          break;
        }
        try {
          final id = record.id;
          if (id == null) continue;
          // Text-only: photos stay on-device (see class docs).
          final res = await BackendApi.instance.uploadScan(
            productName: record.productName,
            category: record.category,
            imagePaths: const [],
            reportJson: record.reportJson,
            ocrText: record.ocrText,
          );
          final serverId = res['id']?.toString() ?? '';
          if (serverId.isNotEmpty) {
            await OcrStore.instance.markScanSynced(id, serverId);
            uploaded++;
            _failures = 0;
          } else {
            // Server 2xx without an id: don't mark synced (would lose the
            // row), but don't hammer either — record and move to next row.
            lastError ??= 'Server accepted the scan but gave no id.';
          }
        } on BackendException catch (e) {
          if (e.statusCode == 401) {
            // Token expired/invalid — every further row would 401 too, so
            // abort the batch NOW instead of sleeping through all 50 rows.
            // Clear the dead token so the UI flips to the signed-out state.
            _failures++;
            lastError = 'Session expired — please sign in again.';
            lastErrorIsAuth = true;
            await ServerConfig.instance.clearToken();
            throw BackendException(
                'Session expired — please sign in again.',
                statusCode: 401);
          }
          _failures++;
          // 400/validation errors will fail identically on retry: keep the
          // row queued, remember the message, move on WITHOUT a long sleep
          // (the old exponential backoff held the "Syncing…" spinner for
          // minutes and looked like an infinite loop).
          lastError = e.message.isNotEmpty ? e.message : 'Upload failed.';
          if (e.statusCode != null && e.statusCode! >= 400 && e.statusCode! < 500 && e.statusCode != 408 && e.statusCode != 429) {
            continue; // client error — retrying immediately won't help.
          }
          await Future<void>.delayed(const Duration(seconds: 1));
        } catch (e) {
          _failures++;
          // Network/timeout/DNS: short pause then next row; the whole batch
          // still finishes in seconds, not minutes.
          final msg = e.toString().replaceFirst('Exception: ', '');
          lastError = msg.length > 160 ? '${msg.substring(0, 160)}…' : msg;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    } finally {
      _running = false;
    }
    final remaining = await OcrStore.instance.countUnsyncedScans().catchError((_) => 0);
    return (uploaded, remaining);
  }

  Future<bool> _online() async {
    try {
      final states = await Connectivity().checkConnectivity();
      if (states.contains(ConnectivityResult.none) && states.length == 1) {
        return false;
      }
      return true;
    } catch (_) {
      return true; // connectivity plugin unavailable (desktop) — try anyway.
    }
  }
}
