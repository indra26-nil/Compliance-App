# complience_app — offline Legal Metrology compliance checker

Flutter app (Android-first, fully offline). Officer photographs a product's
label panels → on-device OCR → declaration extraction → LM-PCR 2011 rule
check → per-product report card, saved locally, exportable to CSV/Excel.

> **Full documentation (architecture, rules, storage, backend contract,
> roadmap): see [`../../README.md`](../../README.md).**

## Quick start

```bash
flutter pub get
flutter run                    # Android device, arm64, API 24+
flutter build apk --release    # field demo APK
flutter analyze
```

Offline OCR (PP-OCRv5 ONNX) runs on Android/iOS only; desktop/web show an
explanatory message instead of crashing.

## Key files

- `lib/home_page.dart` — scanner setup (product name, category, 1..N photos)
- `lib/screens/compliance_report_screen.dart` — the report card ★
- `lib/services/declaration_extractor.dart` — (B) OCR text → declarations
- `lib/services/rule_engine.dart` — (C) LM-PCR 2011 rule catalog
- `lib/services/scan_pipeline.dart` — multi-photo orchestration
- `lib/services/backend_api.dart` + `docs/backend_api_contract.md` — server spec (D/E/F, not built)
open