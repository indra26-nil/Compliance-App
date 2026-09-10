/// D/E/F — Backend API client (IMPLEMENTED against regulation-engine v2).
///
/// The app stays **offline-first**: scan → extract → rule-check → report all
/// run on-device. This client only *copies* the finished report to the
/// server (fire-and-forget from [ScanPipeline] via [SyncService]) so the
/// report card never blocks on network.
///
/// Contract: `docs/backend_api_contract.md` (field names frozen).
/// Server: `regulation-engine/` (deploy per its README).
///
/// ```text
/// login()                  ->        POST /api/auth/login
/// uploadScan()             ->        POST /api/scans (multipart)
/// listScans()              ->        GET  /api/scans?q=&verdict=
/// fetchDashboard()         ->        GET  /api/dashboard/summary
/// downloadReportPdf()      ->        GET  /api/reports/:id.pdf
/// downloadReportCsv()      ->        GET  /api/reports.csv
/// ```
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_config.dart';

class BackendException implements Exception {
  BackendException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'BackendException($statusCode): $message';
}

/// Offline-first server client. Every method throws [BackendException] when
/// the server is unreachable / rejects the call — callers must catch and
/// keep the local row as source of truth.
class BackendApi {
  BackendApi._();
  static final BackendApi instance = BackendApi._();

  Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await ServerConfig.instance.token();
    return {
      if (json) 'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty)
        'Authorization': 'Bearer $token',
    };
  }

  Future<dynamic> _decode(http.Response res) async {
    if (res.statusCode == 401) {
      throw BackendException('Not signed in (token missing/expired).',
          statusCode: 401);
    }
    dynamic body;
    try {
      body = jsonDecode(res.body);
    } catch (_) {
      body = null;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final msg = body is Map
          ? (body['message']?.toString() ?? 'Request failed')
          : 'Request failed (${res.statusCode})';
      throw BackendException(msg, statusCode: res.statusCode);
    }
    return body;
  }

  /// `POST /api/auth/login` — officer/supervisor/admin login.
  /// Persists the JWT in secure storage for all other calls.
  Future<Map<String, Object?>> login({
    required String email,
    required String password,
  }) async {
    final base = await ServerConfig.instance.baseUrl();
    final res = await http
        .post(
          Uri.parse('$base/api/auth/login'),
          headers: await _headers(json: true),
          body: jsonEncode({'email': email.trim(), 'password': password}),
        )
        .timeout(const Duration(seconds: 20));
    final body = await _decode(res) as Map<String, dynamic>;
    final token = body['token']?.toString() ?? '';
    if (token.isEmpty) throw BackendException('Login gave no token.');
    await ServerConfig.instance.setToken(token);
    await ServerConfig.instance
        .setUserJson(jsonEncode(body['user'] ?? const {}));
    return Map<String, Object?>.from(body);
  }

  Future<void> logout() => ServerConfig.instance.clearToken();

  /// `POST /api/scans` (multipart/form-data) — authoritative server record.
  ///
  /// Parts: `photos[]` (1..N image files), fields: `productName`, `category`
  /// (`general|food`), `reportJson` (stringified [ComplianceReport.toJson]),
  /// `ocrText`, `capturedAt` (ISO-8601), optional `gpsLat/Lng`.
  /// Response: `{ "id": "<serverId>", "verdict": "...", "score": 0 }`.
  Future<Map<String, Object?>> uploadScan({
    required String productName,
    required String category,
    required List<String> imagePaths,
    required Map<String, Object?> reportJson,
    required String ocrText,
    DateTime? capturedAt,
    double? gpsLat,
    double? gpsLng,
  }) async {
    final base = await ServerConfig.instance.baseUrl();
    final req = http.MultipartRequest('POST', Uri.parse('$base/api/scans'));
    final headers = await _headers();
    req.headers.addAll(headers);
    req.fields['productName'] = productName;
    req.fields['category'] = category;
    req.fields['reportJson'] = jsonEncode(reportJson);
    req.fields['ocrText'] = ocrText;
    req.fields['capturedAt'] =
        (capturedAt ?? DateTime.now()).toIso8601String();
    if (gpsLat != null && gpsLng != null) {
      req.fields['gpsLat'] = gpsLat.toString();
      req.fields['gpsLng'] = gpsLng.toString();
    }
    for (final p in imagePaths) {
      req.files.add(await http.MultipartFile.fromPath('photos', p));
    }
    // Text-only uploads (no photos) finish in seconds — a short timeout
    // keeps SyncService batches from hanging per row when the server is
    // unreachable (the old 90s × 50 rows looked like an infinite loop).
    final streamed = await req.send().timeout(const Duration(seconds: 30));
    final res = await http.Response.fromStream(streamed);
    final body = await _decode(res) as Map<String, dynamic>;
    return Map<String, Object?>.from(body);
  }

  /// `GET /api/scans?q=&verdict=&page=` — server repository / search (E).
  /// Local history stays in `OcrStore.product_scans`; this is the shared index.
  Future<List<Map<String, Object?>>> listScans({
    String query = '',
    String verdict = '',
    int page = 1,
  }) async {
    final base = await ServerConfig.instance.baseUrl();
    final uri = Uri.parse('$base/api/scans').replace(queryParameters: {
      if (query.isNotEmpty) 'q': query,
      if (verdict.isNotEmpty) 'verdict': verdict,
      'page': '$page',
    });
    final res = await http
        .get(uri, headers: await _headers())
        .timeout(const Duration(seconds: 20));
    final body = await _decode(res) as Map<String, dynamic>;
    final scans = (body['scans'] as List? ?? []);
    return scans
        .map((e) => Map<String, Object?>.from(e as Map))
        .toList();
  }

  /// `GET /api/dashboard/summary` — enforcement dashboard aggregates (E).
  Future<Map<String, Object?>> fetchDashboard() async {
    final base = await ServerConfig.instance.baseUrl();
    final res = await http
        .get(Uri.parse('$base/api/dashboard/summary'),
            headers: await _headers())
        .timeout(const Duration(seconds: 20));
    final body = await _decode(res) as Map<String, dynamic>;
    return Map<String, Object?>.from(body);
  }

  /// `GET /api/reports/:id.pdf` — server-rendered compliance PDF (F).
  /// Returns PDF bytes (photo evidence + violation table + officer stamp).
  Future<List<int>> downloadReportPdf(String serverId) async {
    final base = await ServerConfig.instance.baseUrl();
    final res = await http
        .get(Uri.parse('$base/api/reports/$serverId.pdf'),
            headers: await _headers())
        .timeout(const Duration(seconds: 60));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendException('PDF download failed (${res.statusCode}).',
          statusCode: res.statusCode);
    }
    return res.bodyBytes;
  }

  /// `GET /api/reports.csv` — server bulk export (F). Same 31+1 column order
  /// as the offline CSV in `export_service.dart`.
  Future<String> downloadReportCsv() async {
    final base = await ServerConfig.instance.baseUrl();
    final res = await http
        .get(Uri.parse('$base/api/reports.csv'), headers: await _headers())
        .timeout(const Duration(seconds: 60));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw BackendException('CSV download failed (${res.statusCode}).',
          statusCode: res.statusCode);
    }
    return res.body;
  }
}
