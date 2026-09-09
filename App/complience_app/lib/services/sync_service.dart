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
///   (`connectivity_plus`); failures retry with exponential backoff on the
///   next enqueue / app start / manual "Sync now".
/// * Text-only sync: report JSON + OCR text go up; photos stay on-device.
///   (Photo evidence upload is a server-side switch away when needed —
///   pass paths to [BackendApi.uploadScan].)

class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  bool _running = false;
  int _failures = 0;

  /// Queue one local scan for upload (or nudge the queue). Never throws.
  void enqueue([int? localId]) {
    unawaited(syncNow());
  }

  /// Upload all unsynced rows. Returns (uploaded, remaining).
  Future<(int, int)> syncNow() async {
    if (_running) return (0, 0);
    _running = true;
    var uploaded = 0;
    try {
      final token = await ServerConfig.instance.token();
      if (token == null || token.isEmpty) return (0, 0);
      if (!await _online()) return (0, 0);

      final pending =
          await OcrStore.instance.listUnsyncedScans(limit: 50);
      for (final record in pending) {
        if (!await _online()) break;
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
          }
        } catch (_) {
          _failures++;
          // Exponential backoff before the next row in this batch.
          final wait = Duration(
              seconds: _failures <= 1 ? 2 : _failures >= 5 ? 60 : 1 << _failures);
          await Future<void>.delayed(wait);
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
