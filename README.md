# Compliance App — SIH: Legal Metrology (Packaged Commodities) Rules, 2011

Mobile-first, **fully offline** compliance checker for packaged-commodity
labels. An enforcement officer photographs a product's label panels
(front / back / sides / MRP close-up), the app extracts the mandatory
declarations on-device, validates them against the Legal Metrology
(Packaged Commodities) Rules, 2011, and produces a per-product **report
card** (COMPLIANT / NON-COMPLIANT / NEEDS REVIEW + score + per-rule
evidence). All scans are saved locally and exportable as an
Excel-compatible CSV.

Built for the Smart India Hackathon problem statement on automated
detection of missing / incorrect / non-standard declarations
(MRP, net quantity, dates, manufacturer, consumer-care, font-size
readability, …).

---

## 1. App location — where to run what

| Piece | Path | Status |
|---|---|---|
| **Flutter app (the product)** | `App/complience_app/` | ✅ Working, offline-first + server sync |
| Backend API + dashboard + reports (D/E/F) | `regulation-engine/` (+ `/dashboard`) | ✅ Built, contract-live (see below) |
| Backend contract | `App/complience_app/docs/backend_api_contract.md` | ✅ Frozen + implemented (§6) |
| Flutter server client | `App/complience_app/lib/services/backend_api.dart` + `server_config.dart` + `sync_service.dart` | ✅ Live (fire-and-forget queue) |
| Legacy Java OCR prototype | `OCR/` | ❄️ Frozen — superseded by on-device PP-OCRv5 |
| Empty Python scaffold | `src/compliance_app/` | ❄️ Unused |

### Run the app (Android — primary target)

```bash
cd App/complience_app
flutter pub get
flutter run            # connected Android device, arm64, API 24+
```

Offline OCR works only on **Android/iOS** (ONNX backend). On desktop/web the
app opens but scanning shows an explanatory message instead of crashing.

```bash
flutter build apk --release          # field demo APK
flutter build web                    # reuse for the official dashboard later
flutter analyze                      # 0 errors/warnings (style infos only)
```

First launch copies the bundled PP-OCRv5 models from assets
(`assets/models/`) to app storage — one-time, ~1–2 s, fully offline after.

---

## 2. User flow

```
Home (product name + category + 1..N photos)
  → "Scan N photos"
  → Processing screen (OCR per photo, never freezes)
  → OCR review (fix lines, auto-clean, pick Regex / Smart assist / Ensemble)
  → Field review (confirm/correct declarations pre-rules)
  → Report card (verdict + score + declarations + rule evidence) [auto-saved]
  → Saved products (search, open any report, export all to CSV/Excel)
```

- **Category** `General` vs `Food`: Food adds the 14-digit FSSAI licence check.
- **Multi-photo**: a declaration found clearly on ANY photo satisfies its
  rule (best-confidence-wins merge). Tip shown in-app: photograph the
  principal panel, MRP close-up, dates and consumer-care block.

---

## 3. Architecture (offline-first)

```
┌─ Flutter App ─────────────────────────────────────────┐
│ Home → Processing → Report card → Saved products      │
│                                                       │
│ lib/services/                                         │
│  ocr_service.dart      PP-OCRv5 engine (isolate-safe) │
│  ocr_preprocess.dart   EXIF fix/upscale (compute)     │
│  ocr_postprocess.dart  denoise, reading order, lexicon│
│  ocr_tokens.dart        geometry-preserving OCR tokens│
│  ocr_layout.dart        tokens → lines → blocks       │
│  field_extractor.dart   label→value spatial extraction│
│  variable_print.dart    dot-matrix re-read branch     │
│  rule_engine.dart       PASS / FAIL / UNVERIFIED      │
│  scan_pipeline.dart     orchestrates 1..N photos      │
│  ocr_store.dart         sqflite: product_scans (v2)   │
│  export_service.dart    all scans → CSV (Excel-ready) │
│  backend_api.dart       STUB for server phase (D/E/F) │
└───────────────────────────────────────────────────────┘
```

Pipeline per product (`scan_pipeline.dart`):

1. **OCR each photo** — `OcrService.recognizeFile` returns raw regions with
   corner points; these become `OcrToken`s. Bounding boxes are NEVER
   flattened into one string (that was the old pipeline's root defect —
   it glued "USE BY…" into the manufacturer block and fused phone+email).
2. **Layout** — `buildLayout` groups tokens into lines + blocks with
   normalized coordinates (resolution independent). Line identity is
   preserved end-to-end.
3. **Extract** — label→value spatial association (same-line-right, same-row,
   nearby) + strict validators + quarantines: barcode digit runs, FSSAI-shaped
   numbers and parenthesized unit-prices (`(Rs. 0.16/g)`) can NEVER become MRP;
   a bare number is never a field without its label; a label alone never
   satisfies its field; ingredients/trademark/slogan lines are never
   brand/product names. OCR confidence and field confidence stored separately,
   with per-field evidence (label, relationship, bbox, method).
4. **Re-read** — UNVERIFIED dot-matrix fields (batch/MRP/dates) are cropped
   from the original photo and re-OCR'd through upscale/contrast variants;
   strict patterns decide, nothing is fabricated.
5. **Rule-check** — PASS / FAIL / **UNVERIFIED**. An extraction gap on a weak
   capture is UNVERIFIED ("retake the date panel"), never FAIL. Only gaps on
   adequately-read packs count as missing.
6. **Save** — full report JSON + photo paths + block-separated OCR text into
   `product_scans`; the report card re-renders from storage, no re-OCR.

---

## 4. Rule catalog (Legal Metrology PCR, 2011)

Implemented in `lib/services/rule_engine.dart` (codes frozen — the future
server API and CSV use the same codes):

| Code | Legal basis | What it checks | Fail severity |
|---|---|---|---|
| `LM-R6-NAME` | R6(1)(a) | manufacturer/packer/importer name + address | ERROR (−15) |
| `LM-R6-COMMON` | R6(1)(b) | common/generic name present | ERROR |
| `LM-R6-NETQ` | R6(1)(c) + R8 | net qty with standard unit (`g/kg/ml/L/pcs…`) | ERROR |
| `LM-R6-DATE-MFG` | R6(1)(d) | month + year of mfr/pack/import | ERROR |
| `LM-R6-DATE-EXP` | FSSAI practice | expiry / best-before visible | WARNING (−5) |
| `LM-R6-MRP` | R6(1)(e) + R9 | MRP present and > 0 | ERROR |
| `LM-R6-MRP-TAX` | R9 | “inclusive of all taxes” wording | WARNING |
| `LM-R9-SINGLE-MRP` | R9 | single MRP (dual MRP flagged for review) | REVIEW (−3) |
| `LM-R6-CARE` | R6(1)(f) | consumer-care phone + email (partial = warning) | ERROR if both missing |
| `LM-R6-ORIGIN` | import proviso | country of origin when import mentioned | ERROR (conditional) |
| `LM-R6-BATCH` | traceability | batch / lot / code | WARNING |
| `LM-FOOD-FSSAI` | FSS Act | 14-digit FSSAI Lic. No. (food only) | ERROR |
| `LM-READ-QUALITY` | legibility proxy | OCR mean-confidence based retake guidance | WARNING/REVIEW |
| `LM-R7-FONT` | R7 schedule | **manual-review gate** (see §6) | REVIEW |

Verdict: any fail → **NON-COMPLIANT**; else any unverified/warning/review →
**NEEDS REVIEW** ("could not verify X — not proven missing", with a retake
action per rule); else **COMPLIANT**. UNVERIFIED scores −5 (vs −15 for FAIL),
warnings −5, manual review −3. The report card renders the three states
distinctly (✓ PASS green, ✕ FAIL red, UNVERIFIED orange with guidance).

---

## 5. Screens (`lib/screens/` + `lib/home_page.dart`)

| Screen | File | Purpose |
|---|---|---|
| Scanner setup | `lib/home_page.dart` | name, category, multi-photo grid, Scan button |
| Loader | `processing_screen.dart` | OCR per photo + progress + retry |
| **OCR review** | `ocr_review_screen.dart` | fix lines, auto-clean, Regex/Smart-assist/Ensemble pick |
| **Field review** | `field_review_screen.dart` | confirm/correct declarations pre-rules |
| **Report card** | `compliance_report_screen.dart` | verdict banner, declarations table, rule cards with evidence, OCR text, rename, share CSV |
| Saved products | `history_screen.dart` | Products tab (search, verdict dots, export-all) + Old scans tab (legacy data) |
| Legacy OCR view | `result_screen.dart` | raw-text view for pre-compliance scans |

---

## 6. Honest limitations (say these to judges — don't hide them)

- **Font size in mm cannot be measured from pixels alone** (needs a scale
  reference). `LM-R7-FONT` is therefore a manual-review gate showing the R7
  table (≤100 cm²→1 mm, 100–500→2 mm, 500–2500→4 mm, >2500→6 mm) instead of
  a fabricated verdict. Readability is proxied via OCR confidence +
  blur/glare-free retake guidance.
- **Generic/brand name extraction is heuristic** (longest label-like line,
  low confidence by design) and surfaces as “confirm on pack” rather than a
  false certainty.
- OCR language: English (+ numerals/symbols); Hindi label support is roadmap.

---

## 7. Local storage (`ocr_store.dart`, sqflite `ocr_history.db`)

- `ocr_records` (v1, legacy) — single-photo OCR texts, kept untouched.
- `product_scans` (v2) — one row per product:
  `productName, category, imagePathsJson, ocrText, reportJson (full
  ComplianceReport), verdict, score, photoCount, meanConfidence,
  regionCount, createdAt`.
- **Export** (`export_service.dart`): all rows → timestamped CSV
  (31 frozen columns — same order the future `GET /api/reports.csv` must
  emit), shared via the OS share sheet. Opens directly in Excel/Sheets.

---

## 8. Server phase — D / E / F (built, 2026-09)

Live in **`regulation-engine/` v2** (deploy + storage + app-connect guide:
`regulation-engine/README.md`); the frozen contract still lives at
**`App/complience_app/docs/backend_api_contract.md`** (§6 logs the build).

- **D**: `POST /api/auth/login` (JWT 12h, officer/supervisor/admin +
  `POST /api/auth/register` bootstrap), `POST /api/scans` (multipart
  `photos[]` ≤8 + `reportJson` verbatim → `{id,verdict,score,corrected}`),
  `GET /api/scans…` (q/verdict/category/page/limit), versioned
  `GET /api/regulations` (`general` + `food`, `2026.09`, full `LM-R6-*`
  catalog). Import-case bugs fixed; legacy `/api/products|/validations`
  kept. Seeded demo: `officer@gov.in / officer123`,
  `admin@gov.in / admin123`.
- **E**: `GET /api/dashboard/summary` (KPIs, top violations, recent) +
  static enforcement register at `/dashboard` (ledger-styled, login,
  tallies, ranked violations, search table, file drawer with evidence).
- **F**: `GET /api/reports/:id.pdf` (pdfkit archival copy mirroring the
  report card) + `GET /api/reports.csv` (same column order as the offline
  export — server and device CSVs diff cleanly).
- **App wiring**: `BackendApi` over `http`, URL via
  `--dart-define=API_BASE_URL=` or Server Settings, JWT in secure storage,
  `SyncService` fire-and-forget queue (online-gated, backoff) hooked into
  `ScanPipeline.checkAndSave`, `product_scans` v3 (`serverId`, `synced`),
  sync chips + official-PDF button on the report card.
- **Host**: API on Render (`render.yaml` Blueprint), DB on MongoDB Atlas
  (free M0), photos on Cloudinary (free tier; local `uploads/` for dev),
  dashboard served from the same API at `/dashboard`.

---

## 9. Repo map (active files)

```
App/complience_app/
  lib/home_page.dart                  scanner setup (multi-photo)
  lib/screens/processing_screen.dart  OCR loader (stage 1)
  lib/screens/ocr_review_screen.dart  line fixes + Regex/Smart-assist/Ensemble pick
  lib/screens/field_review_screen.dart  declaration fixes pre-rules
  lib/screens/compliance_report_screen.dart   report card  ★
  lib/screens/history_screen.dart     saved products + CSV export
  lib/screens/result_screen.dart      legacy OCR view
  lib/services/ocr_service.dart       PP-OCRv5 singleton + stages
  lib/services/ocr_preprocess.dart    isolate pre-processing
  lib/services/ocr_postprocess.dart   denoise + food lexicon
  lib/services/ocr_tokens.dart        geometry-preserving OCR tokens
  lib/services/ocr_layout.dart        lines + blocks reconstruction
  lib/services/field_extractor.dart   spatial label→value extraction
  lib/services/variable_print.dart    dot-matrix re-read branch
  lib/services/rule_engine.dart       PASS / FAIL / UNVERIFIED catalog
  lib/services/scan_pipeline.dart     multi-photo orchestration
  lib/services/ocr_store.dart         sqflite v2 (product_scans)
  lib/services/export_service.dart    CSV export
  lib/services/backend_api.dart       server stub + endpoint docs
  docs/backend_api_contract.md        D/E/F contract
  test/extraction_pipeline_test.dart  21 tests from both real cases
```

## 10. Roadmap

- [ ] Ruler/scale-card assisted font-size measurement (turn `LM-R7-FONT`
      from review-gate into measured verdict)
- [ ] Hindi + regional-language OCR dictionaries
- [ ] E-commerce listing checker (2017 amendment declarations on PDP URLs)
- [ ] Server (D), web dashboard (E), signed PDFs (F) per the contract
- [ ] Rename `complience_app` → `compliance_app` (cosmetic, last)
