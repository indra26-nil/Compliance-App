/// Local "Excel-like" export: all saved product scans -> one CSV file.
///
/// CSV opens directly in Excel / Google Sheets / LibreOffice, which satisfies
/// the "export all scanned products' data in an xl-like sheet" requirement
/// with zero native dependencies and full offline support.
///
/// Columns (frozen — the future server `GET /api/reports.csv` (F) must emit
/// the same header order; see `docs/backend_api_contract.md`):
/// id, product_name, category, scanned_at, verdict, score, photo_count,
/// mean_confidence, region_count, generic_name, brand, net_qty_raw,
/// net_qty_value, net_qty_unit, mrp_raw, mrp_value, mrp_tax_phrase, mfg_raw,
/// exp_raw, manufacturer_name, manufacturer_address, care_phone, care_email,
/// country_of_origin, batch_no, fssai_lic, fail_count, warning_count,
/// review_count, failed_rule_codes, photo_paths, unverified_rule_codes
/// (`unverified_rule_codes` appended 2026-09 for the three-state engine;
/// appended at the end so existing positions stay stable.)
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'ocr_store.dart';
import 'rule_engine.dart';

class ExportService {
  const ExportService();

  static const List<String> headers = [
    'id',
    'product_name',
    'category',
    'scanned_at',
    'verdict',
    'score',
    'photo_count',
    'mean_confidence',
    'region_count',
    'generic_name',
    'brand',
    'net_qty_raw',
    'net_qty_value',
    'net_qty_unit',
    'mrp_raw',
    'mrp_value',
    'mrp_tax_phrase',
    'mfg_raw',
    'exp_raw',
    'manufacturer_name',
    'manufacturer_address',
    'care_phone',
    'care_email',
    'country_of_origin',
    'batch_no',
    'fssai_lic',
    'fail_count',
    'warning_count',
    'review_count',
    'failed_rule_codes',
    'photo_paths',
    'unverified_rule_codes',
  ];

  /// Builds the CSV text for [records] (header + one row per scan).
  String buildCsv(List<ProductScanRecord> records) {
    final buf = StringBuffer();
    buf.writeln(headers.map(_cell).join(','));
    for (final r in records) {
      buf.writeln(_row(r).map(_cell).join(','));
    }
    return buf.toString();
  }

  /// Exports ALL saved product scans to a timestamped CSV file in the
  /// temporary directory. Returns the file (caller shares/saves it).
  /// Throws [StateError] when there is nothing to export.
  Future<File> exportAllScansToCsv() async {
    final records = await OcrStore.instance.listProductScans(limit: 10000);
    if (records.isEmpty) {
      throw StateError('No product scans saved yet.');
    }
    final csv = buildCsv(records);
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final file = File('${dir.path}/product_scans_$stamp.csv');
    return file.writeAsString(csv);
  }

  /// Exports a SINGLE scan (used by the report card's share button).
  Future<File> exportSingleScanToCsv(ProductScanRecord record) async {
    final csv = buildCsv([record]);
    final dir = await getTemporaryDirectory();
    final safeName = record.productName
        .replaceAll(RegExp(r'[^\w\- ]+'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    final base = safeName.isEmpty ? 'product' : safeName;
    final file = File('${dir.path}/${base}_${record.id ?? 'scan'}.csv');
    return file.writeAsString(csv);
  }

  List<String> _row(ProductScanRecord r) {
    ComplianceReport? report;
    try {
      report = ComplianceReport.fromJson(r.reportJson);
    } catch (_) {
      report = null;
    }
    final d = report?.declarations;
    String val(String field) => d?.obs(field).value ?? '';
    String data(String field, String key) =>
        d?.obs(field).data[key]?.toString() ?? '';
    final failedCodes = report == null
        ? ''
        : report.results
            .where((e) => e.isFail)
            .map((e) => e.code)
            .join(';');
    // Tax phrase isn't an extracted field — detect from stored OCR text,
    // same regex as the rule engine.
    final taxPhrase = RegExp(r'inclusive\s+of\s+all\s+taxes?',
            caseSensitive: false)
        .hasMatch(r.ocrText);
    final unverifiedCodes = report == null
        ? ''
        : report.results
            .where((e) => e.isUnverified)
            .map((e) => e.code)
            .join(';');
    return [
      '${r.id ?? ''}',
      r.productName,
      r.category,
      r.createdAt.toIso8601String(),
      r.verdict,
      '${r.score}',
      '${r.photoCount}',
      r.meanConfidence.toStringAsFixed(2),
      '${r.regionCount}',
      val('genericName'),
      val('brand'),
      val('netQty'),
      data('netQty', 'value'),
      data('netQty', 'unit'),
      val('mrp'),
      data('mrp', 'value'),
      taxPhrase ? 'yes' : 'no',
      val('mfg'),
      val('exp'),
      // Manufacturer name lives in value; address in data (see extractor).
      val('manufacturer'),
      data('manufacturer', 'address'),
      val('carePhone'),
      val('careEmail'),
      val('origin'),
      val('batch'),
      val('fssai'),
      '${report?.failCount ?? ''}',
      '${report?.warningCount ?? ''}',
      '${report?.reviewCount ?? ''}',
      failedCodes,
      r.imagePaths.join(';'),
      unverifiedCodes,
    ];
  }

  /// RFC-4180 cell escaping: quote when the value contains , " or newline.
  static String _cell(String value) {
    if (value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
