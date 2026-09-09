# Backend API Contract — D / E / F (implement later)

The Flutter app is **offline-first**: scan → extract → rule-check → report card
all run on-device (`lib/services/`). This document freezes the server contract
so D (API), E (dashboard) and F (reports) can be built later against the
existing `regulation-engine/` Express app **without changing the mobile code**.

> Field names, rule codes (`LM-R6-*`) and CSV column order are frozen.
> The mobile models (`DeclarationSet`, `ComplianceReport`, `ProductScanRecord`)
> already emit exactly these shapes.

## 0. Conventions

- Base URL: `https://<host>/api`
- Auth: `Authorization: Bearer <jwt>` (roles: `officer | supervisor | admin`).
- Errors: `{ "success": false, "message": "...", "error": "..." }`
- Dates: ISO-8601. Verdicts: `compliant | nonCompliant | needsReview`.
- Categories: `general | food`.

## 1. D — Core API

### POST /api/auth/login
Request:
```json
{ "email": "officer@gov.in", "password": "***" }
```
Response `200`:
```json
{ "success": true, "token": "<jwt>",
  "user": { "id": "...", "name": "...", "role": "officer" } }
```
Notes: bcrypt passwords, JWT expiry 12h. Mobile stores token in
`flutter_secure_storage`. All routes below require it.

### POST /api/scans (multipart/form-data)
Authoritative server record for one product scan (1..N photos).

Parts / fields:

| Part | Type | Notes |
|---|---|---|
| `photos[]` | file × 1..N | original label images → object storage (S3/Cloudinary/local `uploads/`) |
| `productName` | string | user-entered |
| `category` | `general\|food` | selects FSSAI rule |
| `reportJson` | stringified JSON | `ComplianceReport.toJson()` verbatim from device |
| `ocrText` | string | combined OCR text (audit + search) |
| `officerId` | string | from JWT |
| `capturedAt` | ISO-8601 | device clock |
| `gpsLat`, `gpsLng` | number? | optional enforcement metadata |

Response `201`:
```json
{ "success": true, "id": "<serverId>", "verdict": "nonCompliant",
  "score": 62, "corrected": false }
```
Server MAY re-run extraction + rules (same catalog) and return a corrected
verdict with `"corrected": true` plus `corrections[]`. Mobile keeps its local
row; add `serverId` + `synced` columns to `product_scans` when implementing.

Maps to: `BackendApi.uploadScan()` → call from `ScanPipeline` step 5
(fire-and-forget queue, exponential backoff, `connectivity_plus` gated).

### GET /api/scans?q=&verdict=&category=&page=&limit=
Shared repository / search. Response `200`:
```json
{ "success": true, "page": 1, "total": 128,
  "scans": [ { "id": "...", "productName": "...", "category": "food",
    "verdict": "nonCompliant", "score": 62, "photoCount": 3,
    "createdAt": "2026-…", "thumbnailUrl": "https://…" } ] }
```
Maps to: `BackendApi.listScans()`.

### GET /api/scans/:id
Full detail (report JSON + image URLs). Mobile `ProductScanRecord` is the
offline mirror of this resource.

### GET /api/regulations / POST /api/regulations
Expose the rule catalog (already partially in `regulation-engine`):
`{ category, version, effectiveFrom, requiredFields[], fontTable{}, rules[] }`.
Bump `version` when the gazette changes; mobile displays it on the report card.

## 2. E — Dashboard (enforcement officials)

### GET /api/dashboard/summary
Response `200`:
```json
{ "success": true, "totalScans": 128, "passRate": 0.41,
  "byVerdict": { "compliant": 52, "nonCompliant": 48, "needsReview": 28 },
  "topViolations": [ { "code": "LM-R6-MRP", "count": 31 } ],
  "recent": [ { "id": "…", "productName": "…", "verdict": "…", "score": 0 } ] }
```
Web dashboard (Flutter Web reuse or React) renders KPI cards, violation bar
chart, searchable table, scan detail with evidence. Maps to:
`BackendApi.fetchDashboard()`.

## 3. F — Reports

### GET /api/reports/:id.pdf
Official archival PDF: header (product, officer, date), verdict + score,
violation table (rule code / clause / evidence / photo ref), photo evidence
appendix, officer signature block. Mobile already shows the same content in
`ComplianceReportScreen`; the server PDF is the signed copy.
Maps to: `BackendApi.downloadReportPdf()`.

### GET /api/reports.csv (server-side bulk export)
Same header order as the **offline CSV** (`ExportService.headers`, 31 columns:
`id,product_name,category,scanned_at,verdict,score,…,failed_rule_codes,photo_paths`).
Guarantee: a server CSV and a device CSV for the same scans are diff-able
modulo `id`/`photo_paths` (URLs vs local paths).

## 4. Mongo sketch (extends current models)

```js
// Scan (new) — mirrors ProductScanRecord
{ productName, category, imageUrls:[String], thumbnailUrl,
  ocrText, reportJson:Object, verdict, score, photoCount,
  meanConfidence, regionCount, officerId:ObjectId, gps:{lat,lng},
  serverValidated:Boolean, createdAt }
// User (new) — { name, email(unique), passwordHash, role, createdAt }
// Product / Regulation / ValidationResult — keep, add `version` to Regulation.
```

## 5. Build checklist for D/E/F day

1. Fix `regulation-engine` import-case bugs (`productController`,
   `regulationController`, `ValidationResult`, `validationEngine` filenames).
2. Add `User` + JWT middleware + `Scan` model + the 5 routes above.
3. Local `uploads/` first; S3 env swap later (`S3_BUCKET`, `S3_REGION`).
4. `pdfkit` template for F reusing the mobile report-card sections.
5. Deploy: API on Render/Railway, Mongo Atlas, web dashboard on Vercel;
   record URLs in `lib/services/backend_api.dart` header.
