/// D/E/F — Backend API stub + endpoint documentation (NOT implemented).
///
/// The app is intentionally **offline-first** for the hackathon field demo:
/// scan -> extract -> rule-check -> report all run on-device (see
/// `scan_pipeline.dart`, `field_extractor.dart`, `rule_engine.dart`).
///
/// When you build the server (D), dashboard (E) and report archive (F),
/// implement THESE methods against the existing `regulation-engine/`
/// Express app and extend it per the contract in
/// `docs/backend_api_contract.md`. Field names here already match that
/// contract — do not rename them.
///
/// ```text
/// Flutter (this file)                regulation-engine (extend it)
/// ───────────────────                ─────────────────────────────
/// login()                  ->        POST /api/auth/login
/// uploadScan()             ->        POST /api/scans (multipart)
/// listScans()              ->        GET  /api/scans?q=&verdict=
/// fetchDashboard()         ->        GET  /api/dashboard/summary
/// downloadReportPdf()      ->        GET  /api/reports/:id.pdf
/// downloadReportCsv()      ->        GET  /api/reports.csv  (server-side;
///                                    local CSV export in `export_service.dart`
///                                    already covers the offline equivalent)
/// ```
///
/// Auth: JWT Bearer in `Authorization` header, roles
/// `officer | supervisor | admin` (RBAC enforced server-side).
/// Sync strategy: keep the local `product_scans` row as source of truth,
/// add a `synced`/`serverId` column later, upload with exponential backoff
/// when `connectivity_plus` reports online. Never block the report card on
/// upload — fire-and-forget from `ScanPipeline` (see its TODO).
library;

/// Offline stub: every method throws [UnimplementedError] until D is built.
///
/// Each method's doc comment is the implementation spec: HTTP verb + path,
/// request shape, response shape, and which local model maps to it.
class BackendApi {
  BackendApi._();
  static final BackendApi instance = BackendApi._();

  /// `POST /api/auth/login` — officer/supervisor/admin login.
  ///
  /// Request: `{ "email": "...", "password": "..." }`
  /// Response: `{ "token": "jwt", "user": { "id": "...", "name": "...",
  ///   "role": "officer|supervisor|admin" } }`
  /// Client: persist `token` in `flutter_secure_storage`, attach as
  /// `Authorization: Bearer token` on all other calls.
  Future<Map<String, Object?>> login({
    required String email,
    required String password,
  }) {
    throw UnimplementedError(
        'TODO(BACKEND-D): POST /api/auth/login — see docs/backend_api_contract.md');
  }

  /// `POST /api/scans` (multipart/form-data) — authoritative server record.
  ///
  /// Parts: `photos[]` (1..N image files), fields: `productName`, `category`
  /// (`general|food`), `reportJson` (stringified [ComplianceReport.toJson]),
  /// `ocrText`, `officerId`, `capturedAt` (ISO-8601), optional `gpsLat/Lng`.
  /// Response: `{ "id": "<serverId>", "verdict": "...", "score": 0 }`
  /// (server MAY re-run extraction+rules and return corrected verdict).
  Future<Map<String, Object?>> uploadScan({
    required String productName,
    required String category,
    required List<String> imagePaths,
    required Map<String, Object?> reportJson,
    required String ocrText,
  }) {
    throw UnimplementedError(
        'TODO(BACKEND-D): POST /api/scans — see docs/backend_api_contract.md');
  }

  /// `GET /api/scans?q=&verdict=&page=` — server repository / search (E).
  ///
  /// Used by the web dashboard and by future cross-device history. Local
  /// history stays in `OcrStore.product_scans`; this is the shared index.
  Future<List<Map<String, Object?>>> listScans({
    String query = '',
    String verdict = '',
    int page = 1,
  }) {
    throw UnimplementedError(
        'TODO(BACKEND-E): GET /api/scans — see docs/backend_api_contract.md');
  }

  /// `GET /api/dashboard/summary` — enforcement dashboard aggregates (E).
  ///
  /// Response: `{ "totalScans": 0, "passRate": 0.0,
  ///   "byVerdict": {"compliant":0,"nonCompliant":0,"needsReview":0},
  ///   "topViolations": [{"code":"LM-R6-MRP","count":0}], "recent": [...] }`
  Future<Map<String, Object?>> fetchDashboard() {
    throw UnimplementedError(
        'TODO(BACKEND-E): GET /api/dashboard/summary — see docs/backend_api_contract.md');
  }

  /// `GET /api/reports/:id.pdf` — server-rendered compliance PDF (F).
  ///
  /// Returns PDF bytes (photo evidence + violation table + officer stamp).
  /// Offline equivalent already exists in-app via the report card + local CSV
  /// export (`export_service.dart`); this is the archival/official copy.
  Future<List<int>> downloadReportPdf(String serverId) {
    throw UnimplementedError(
        'TODO(BACKEND-F): GET /api/reports/:id.pdf — see docs/backend_api_contract.md');
  }
}
