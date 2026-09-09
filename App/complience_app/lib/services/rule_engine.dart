/// Offline rule engine: PASS / FAIL / UNVERIFIED over evidence-backed fields.
///
/// Consumes [ExtractedProduct] (never raw OCR text) — the mandatory
/// IMAGE → OCR → EXTRACTION → STRUCTURED DATA → COMPLIANCE separation.
///
/// ## The three states (Problem 9 — the most important semantic fix)
/// * **PASS** — declaration confidently found and rule-satisfying.
/// * **FAIL** — declaration confidently found but violating, OR no trace of
///   it on an *adequate* capture (dense, confident OCR — absence is then
///   meaningful evidence of absence).
/// * **UNVERIFIED** — hints exist (label seen, weak pattern, poor capture)
///   but nothing provable. Rendered distinctly in the UI with a retake
///   action ("capture a closer image of the date panel"), and scored
///   lightly (−5, not −15). An OCR gap is NEVER called "missing".
///
/// ## Backend handoff (D/E/F)
/// [ComplianceReport.toJson] stays the `POST /api/scans` body and the stored
/// `product_scans.reportJson` shape. Rule codes are frozen; `unverified` is
/// a new status value the dashboard must render alongside pass/fail —
/// see `docs/backend_api_contract.md`.
library;

import 'field_extractor.dart';

/// Product category selects extra rules (food adds FSSAI).
enum ProductCategory { general, food }

/// Final verdict for one product scan.
enum Verdict { compliant, nonCompliant, needsReview }

/// Per-rule outcome. `unverified` is first-class: "could not determine",
/// distinct from both pass and fail.
enum RuleStatus { pass, fail, warning, manualReview, unverified }

/// Severity used for scoring + report coloring.
enum RuleSeverity { error, warning, info }

class RuleResult {
  const RuleResult({
    required this.code,
    required this.title,
    required this.clause,
    required this.field,
    required this.status,
    required this.message,
    this.evidence,
    this.photoIndex,
    required this.severity,
    this.action,
  });

  final String code;
  final String title;
  final String clause;
  final String field;
  final RuleStatus status;
  final String message;
  final String? evidence;
  final int? photoIndex;
  final RuleSeverity severity;

  /// Retake guidance shown for UNVERIFIED rules (e.g. which panel to
  /// re-photograph). Null for pass/fail.
  final String? action;

  bool get isFail => status == RuleStatus.fail;
  bool get isUnverified => status == RuleStatus.unverified;
  bool get isAttention => status != RuleStatus.pass;

  Map<String, Object?> toJson() => {
        'code': code,
        'title': title,
        'clause': clause,
        'field': field,
        'status': status.name,
        'message': message,
        'evidence': evidence,
        'photoIndex': photoIndex,
        'severity': severity.name,
        'action': action,
      };

  factory RuleResult.fromJson(Map<String, Object?> json) => RuleResult(
        code: json['code'] as String? ?? '',
        title: json['title'] as String? ?? '',
        clause: json['clause'] as String? ?? '',
        field: json['field'] as String? ?? '',
        status: RuleStatus.values.firstWhere(
          (e) => e.name == json['status'],
          // Old reports predate `unverified`; unknown values degrade to
          // manualReview rather than crashing the report card.
          orElse: () => RuleStatus.manualReview,
        ),
        message: json['message'] as String? ?? '',
        evidence: json['evidence'] as String?,
        photoIndex: (json['photoIndex'] as num?)?.toInt(),
        severity: RuleSeverity.values.firstWhere(
          (e) => e.name == json['severity'],
          orElse: () => RuleSeverity.info,
        ),
        action: json['action'] as String?,
      );
}

class ComplianceReport {
  const ComplianceReport({
    required this.verdict,
    required this.score,
    required this.results,
    required this.declarations,
    required this.category,
    required this.checkedAt,
    this.meanConfidence = 0,
    this.regionCount = 0,
    this.photoCount = 1,
    this.combinedText = '',
    this.quality,
  });

  final Verdict verdict;
  final int score;
  final List<RuleResult> results;
  final ExtractedProduct declarations;
  final ProductCategory category;
  final DateTime checkedAt;
  final double meanConfidence;
  final int regionCount;
  final int photoCount;
  final String combinedText;
  final ExtractionQuality? quality;

  int get failCount => results.where((r) => r.isFail).length;
  int get warningCount =>
      results.where((r) => r.status == RuleStatus.warning).length;
  int get reviewCount =>
      results.where((r) => r.status == RuleStatus.manualReview).length;
  int get unverifiedCount => results.where((r) => r.isUnverified).length;
  int get passCount => results.where((r) => r.status == RuleStatus.pass).length;

  Map<String, Object?> toJson() => {
        'verdict': verdict.name,
        'score': score,
        'results': results.map((r) => r.toJson()).toList(),
        'declarations': declarations.toJson(),
        'category': category.name,
        'checkedAt': checkedAt.toIso8601String(),
        'meanConfidence': meanConfidence,
        'regionCount': regionCount,
        'photoCount': photoCount,
        // NOTE: combinedText can be long; backend stores it for audit/search.
        'combinedText': combinedText,
        'quality': quality?.toJson(),
      };

  factory ComplianceReport.fromJson(Map<String, Object?> json) {
    ExtractedProduct declarations;
    try {
      final d = json['declarations'];
      declarations = ExtractedProduct.fromJson(
          Map<String, Object?>.from((d as Map?) ?? {}));
    } catch (_) {
      declarations = const ExtractedProduct(fields: {});
    }
    return ComplianceReport(
      verdict: Verdict.values.firstWhere(
        (e) => e.name == json['verdict'],
        orElse: () => Verdict.needsReview,
      ),
      score: (json['score'] as num?)?.toInt() ?? 0,
      results: ((json['results'] as List?) ?? [])
          .map((e) =>
              RuleResult.fromJson(Map<String, Object?>.from(e as Map)))
          .toList(),
      declarations: declarations,
      category: ProductCategory.values.firstWhere(
        (e) => e.name == json['category'],
        orElse: () => ProductCategory.general,
      ),
      checkedAt:
          DateTime.tryParse(json['checkedAt'] as String? ?? '') ??
              DateTime.now(),
      meanConfidence: (json['meanConfidence'] as num?)?.toDouble() ?? 0,
      regionCount: (json['regionCount'] as num?)?.toInt() ?? 0,
      photoCount: (json['photoCount'] as num?)?.toInt() ?? 1,
      combinedText: json['combinedText'] as String? ?? '',
      quality: null,
    );
  }
}

/// Offline rule checker. No I/O, no singletons.
class RuleEngine {
  const RuleEngine();

  ComplianceReport check(
    ExtractedProduct d, {
    ProductCategory category = ProductCategory.general,
    ExtractionQuality quality = const ExtractionQuality(
        meanConfidence: 0, totalChars: 0, regionCount: 0, photoCount: 1),
    String combinedText = '',
  }) {
    final results = <RuleResult>[];
    // notFound on an adequate capture ⇒ FAIL (meaningful absence);
    // notFound on a poor capture ⇒ UNVERIFIED (gap, not proof).
    RuleStatus absent(FieldObservation o) =>
        quality.adequate ? RuleStatus.fail : RuleStatus.unverified;

    String absentMsg(String what) => quality.adequate
        ? 'Missing — $what not detected on any photo of an adequately read pack.'
        : 'Could not verify — $what not detected and the capture is too '
            'weak to prove absence (see capture quality below).';

    String? actionFor(String panel) =>
        'Capture a closer, flat, glare-free photo of the $panel and re-scan.';

    // ---- 1. Manufacturer / packer / importer ----
    final mfr = d.manufacturer;
    if (mfr.isFound) {
      final addr = (mfr.data['address'] as String? ?? '').trim();
      final role = (mfr.data['role'] as String? ?? 'manufacturer');
      results.add(RuleResult(
        code: 'LM-R6-NAME',
        title: 'Manufacturer / Packer / Importer',
        clause: 'PCR Rule 6(1)(a)',
        field: 'manufacturer',
        status: addr.length >= 8 ? RuleStatus.pass : RuleStatus.warning,
        message: addr.length >= 8
            ? '${_cap(role)} name and address found.'
            : 'Name found but address looks incomplete — verify PIN + full address on pack.',
        evidence: mfr.evidenceText,
        photoIndex: mfr.photoIndex,
        severity: addr.length >= 8 ? RuleSeverity.info : RuleSeverity.warning,
      ));
    } else if (mfr.status == FieldStatus.unverified) {
      results.add(RuleResult(
        code: 'LM-R6-NAME',
        title: 'Manufacturer / Packer / Importer',
        clause: 'PCR Rule 6(1)(a)',
        field: 'manufacturer',
        status: RuleStatus.unverified,
        message:
            'Possible manufacturer block glimpsed but not readable with confidence.',
        evidence: mfr.evidenceText,
        photoIndex: mfr.photoIndex,
        severity: RuleSeverity.warning,
        action: actionFor('manufacturer / marketer panel'),
      ));
    } else {
      final st = absent(mfr);
      results.add(RuleResult(
        code: 'LM-R6-NAME',
        title: 'Manufacturer / Packer / Importer',
        clause: 'PCR Rule 6(1)(a)',
        field: 'manufacturer',
        status: st,
        message: st == RuleStatus.fail
            ? 'Missing — pack must show name + complete address of manufacturer/packer/importer.'
            : absentMsg(
                'name + address of the manufacturer/packer/importer'),
        severity: RuleSeverity.error,
        action: st == RuleStatus.fail ? null : actionFor('address panel'),
      ));
    }

    // ---- 2. Generic name (never ingredients — enforced in extractor) ----
    final generic = d.genericName;
    if (generic.isFound) {
      results.add(RuleResult(
        code: 'LM-R6-COMMON',
        title: 'Common / generic name',
        clause: 'PCR Rule 6(1)(b)',
        field: 'genericName',
        status: RuleStatus.pass,
        message: 'Generic name found.',
        evidence: generic.evidenceText,
        photoIndex: generic.photoIndex,
        severity: RuleSeverity.info,
      ));
    } else if (generic.status == FieldStatus.unverified) {
      results.add(RuleResult(
        code: 'LM-R6-COMMON',
        title: 'Common / generic name',
        clause: 'PCR Rule 6(1)(b)',
        field: 'genericName',
        status: RuleStatus.unverified,
        message:
            'A likely product name ("${generic.value}") needs confirmation against the principal display panel.',
        evidence: generic.evidenceText,
        photoIndex: generic.photoIndex,
        severity: RuleSeverity.warning,
        action: actionFor('front / principal display panel'),
      ));
    } else {
      final st = absent(generic);
      results.add(RuleResult(
        code: 'LM-R6-COMMON',
        title: 'Common / generic name',
        clause: 'PCR Rule 6(1)(b)',
        field: 'genericName',
        status: st,
        message: st == RuleStatus.fail
            ? 'Missing — common/generic name of the commodity not detected.'
            : absentMsg('common/generic name'),
        severity: RuleSeverity.error,
        action: st == RuleStatus.fail
            ? null
            : actionFor('front / principal display panel'),
      ));
    }

    // ---- 3. Net quantity (validator normalizes; invalid can't arrive) ----
    final net = d.netQty;
    if (net.isFound) {
      results.add(RuleResult(
        code: 'LM-R6-NETQ',
        title: 'Net quantity',
        clause: 'PCR Rule 6(1)(c) + Rule 8',
        field: 'netQty',
        status: RuleStatus.pass,
        message: 'Net quantity with standard unit found.',
        evidence:
            '${net.evidenceLabel != null ? '${net.evidenceLabel}: ' : ''}${net.evidenceText}',
        photoIndex: net.photoIndex,
        severity: RuleSeverity.info,
      ));
    } else {
      // No unlabelled fallback exists upstream, so a gap here is either a
      // true absence or a capture problem — never a half-parse.
      final st = absent(net);
      results.add(RuleResult(
        code: 'LM-R6-NETQ',
        title: 'Net quantity',
        clause: 'PCR Rule 6(1)(c) + Rule 8',
        field: 'netQty',
        status: st,
        message: st == RuleStatus.fail
            ? 'Missing — net quantity (weight/measure/count) not detected on any photo.'
            : absentMsg('net quantity declaration'),
        severity: RuleSeverity.error,
        action:
            st == RuleStatus.fail ? null : actionFor('net-quantity panel'),
      ));
    }

    // ---- 4. Dates ----
    results.add(_dateRule(
        d.mfg, 'LM-R6-DATE-MFG', 'Month + year (mfg/pack/import)',
        'PCR Rule 6(1)(d)', quality, actionFor('date-of-manufacture panel'),
        missingIsFail: true));
    results.add(_dateRule(
        d.exp, 'LM-R6-DATE-EXP', 'Expiry / use-by / best-before',
        'FSSAI + best practice', quality, actionFor('expiry / use-by panel'),
        missingIsFail: false));

    // ---- 5. MRP ----
    final mrp = d.mrp;
    if (mrp.isFound) {
      final v = (mrp.data['value'] as num?)?.toDouble();
      final taxPhrase = _taxPhrasePresent(combinedText);
      results.add(RuleResult(
        code: 'LM-R6-MRP',
        title: 'Maximum Retail Price',
        clause: 'PCR Rule 6(1)(e) + Rule 9',
        field: 'mrp',
        status: RuleStatus.pass,
        message:
            'MRP ₹${v?.toStringAsFixed(v % 1 == 0 ? 0 : 2) ?? mrp.value} detected${mrp.method == ExtractMethod.variablePrintPipeline ? ' (dot-matrix re-read)' : ''}.',
        evidence:
            '${mrp.evidenceLabel != null ? '${mrp.evidenceLabel}: ' : ''}${mrp.evidenceText}',
        photoIndex: mrp.photoIndex,
        severity: RuleSeverity.info,
      ));
      results.add(RuleResult(
        code: 'LM-R6-MRP-TAX',
        title: 'MRP includes-taxes phrase',
        clause: 'PCR Rule 9',
        field: 'mrpTaxPhrase',
        status: taxPhrase ? RuleStatus.pass : RuleStatus.warning,
        message: taxPhrase
            ? '"Inclusive of all taxes" found.'
            : 'MRP found but "inclusive of all taxes" not detected — required wording; check the MRP panel photo.',
        severity: taxPhrase ? RuleSeverity.info : RuleSeverity.warning,
      ));
      final mentions = _countMrpMentions(combinedText);
      if (mentions >= 2) {
        results.add(RuleResult(
          code: 'LM-R9-SINGLE-MRP',
          title: 'Single MRP declaration',
          clause: 'PCR Rule 9 (dual MRP prohibited)',
          field: 'mrp',
          status: RuleStatus.manualReview,
          message:
              'Multiple MRP-like mentions ($mentions) across photos — confirm only ONE MRP is declared (sticker + print together = violation).',
          evidence: 'Mentions: $mentions',
          severity: RuleSeverity.warning,
        ));
      }
    } else if (mrp.status == FieldStatus.unverified) {
      results.add(RuleResult(
        code: 'LM-R6-MRP',
        title: 'Maximum Retail Price',
        clause: 'PCR Rule 6(1)(e) + Rule 9',
        field: 'mrp',
        status: RuleStatus.unverified,
        message: mrp.note ??
            'MRP label glimpsed but value unreadable — dot-matrix print suspected.',
        evidence: mrp.evidenceText,
        photoIndex: mrp.photoIndex,
        severity: RuleSeverity.warning,
        action: actionFor('MRP panel (close-up, flat, no glare)'),
      ));
    } else {
      final st = absent(mrp);
      results.add(RuleResult(
        code: 'LM-R6-MRP',
        title: 'Maximum Retail Price',
        clause: 'PCR Rule 6(1)(e) + Rule 9',
        field: 'mrp',
        status: st,
        message: st == RuleStatus.fail
            ? 'Missing — no MRP label found on an adequately read pack.'
            : absentMsg('MRP declaration'),
        severity: RuleSeverity.error,
        action: st == RuleStatus.fail
            ? null
            : actionFor('MRP panel (close-up, flat, no glare)'),
      ));
    }

    // ---- 6. Consumer care ----
    final hasPhone = d.carePhone.isFound;
    final hasEmail = d.careEmail.isFound;
    final anyCareHint = hasPhone ||
        hasEmail ||
        d.carePhone.status == FieldStatus.unverified ||
        d.careEmail.status == FieldStatus.unverified;
    if (hasPhone && hasEmail) {
      results.add(RuleResult(
        code: 'LM-R6-CARE',
        title: 'Consumer-care details',
        clause: 'PCR Rule 6(1)(f)',
        field: 'consumerCare',
        status: RuleStatus.pass,
        message: 'Phone + email found.',
        evidence: '${d.carePhone.value} • ${d.careEmail.value}',
        photoIndex: d.carePhone.photoIndex,
        severity: RuleSeverity.info,
      ));
    } else if (anyCareHint) {
      results.add(RuleResult(
        code: 'LM-R6-CARE',
        title: 'Consumer-care details',
        clause: 'PCR Rule 6(1)(f)',
        field: 'consumerCare',
        status: quality.adequate && !hasPhone && !hasEmail
            ? RuleStatus.warning
            : RuleStatus.unverified,
        message: hasPhone || hasEmail
            ? 'Partial — found ${hasPhone ? "phone" : "email"} but the other channel is unverified; full care details are required.'
            : 'Consumer-care section glimpsed but contacts unreadable.',
        evidence: d.carePhone.evidenceText ?? d.careEmail.evidenceText,
        photoIndex: d.carePhone.photoIndex,
        severity: RuleSeverity.warning,
        action: actionFor('consumer-care block'),
      ));
    } else {
      final st = absent(d.carePhone);
      results.add(RuleResult(
        code: 'LM-R6-CARE',
        title: 'Consumer-care details',
        clause: 'PCR Rule 6(1)(f)',
        field: 'consumerCare',
        status: st,
        message: st == RuleStatus.fail
            ? 'Missing — consumer-care contacts not detected on an adequately read pack.'
            : absentMsg('consumer-care contacts'),
        severity: RuleSeverity.error,
        action:
            st == RuleStatus.fail ? null : actionFor('consumer-care block'),
      ));
    }

    // ---- 7. Origin (conditional: only when import hinted) ----
    final importerHint = (d.manufacturer.data['role'] == 'importer') ||
        RegExp(r'import', caseSensitive: false).hasMatch(combinedText);
    if (importerHint) {
      final origin = d.origin;
      if (origin.isFound) {
        results.add(RuleResult(
          code: 'LM-R6-ORIGIN',
          title: 'Country of origin (import)',
          clause: 'Import proviso to Rule 6',
          field: 'origin',
          status: RuleStatus.pass,
          message: 'Country of origin found.',
          evidence: origin.evidenceText,
          photoIndex: origin.photoIndex,
          severity: RuleSeverity.info,
        ));
      } else {
        results.add(RuleResult(
          code: 'LM-R6-ORIGIN',
          title: 'Country of origin (import)',
          clause: 'Import proviso to Rule 6',
          field: 'origin',
          status: quality.adequate
              ? RuleStatus.fail
              : RuleStatus.unverified,
          message: quality.adequate
              ? 'Pack mentions import but no country of origin detected.'
              : absentMsg('country of origin'),
          severity: RuleSeverity.error,
          action: actionFor('origin declaration'),
        ));
      }
    }

    // ---- 8. Batch ----
    final batch = d.batch;
    if (batch.isFound) {
      results.add(RuleResult(
        code: 'LM-R6-BATCH',
        title: 'Batch / lot / code',
        clause: 'Traceability (with Rule 6(1)(d))',
        field: 'batch',
        status: RuleStatus.pass,
        message:
            'Batch/lot identifier found${batch.method == ExtractMethod.variablePrintPipeline ? ' (dot-matrix re-read)' : ''}.',
        evidence:
            '${batch.evidenceLabel != null ? '${batch.evidenceLabel}: ' : ''}${batch.evidenceText}',
        photoIndex: batch.photoIndex,
        severity: RuleSeverity.info,
      ));
    } else if (batch.status == FieldStatus.unverified) {
      results.add(RuleResult(
        code: 'LM-R6-BATCH',
        title: 'Batch / lot / code',
        clause: 'Traceability (with Rule 6(1)(d))',
        field: 'batch',
        status: RuleStatus.unverified,
        message: batch.note ??
            'Batch label seen but identifier unreadable — dot-matrix print suspected.',
        evidence: batch.evidenceText,
        photoIndex: batch.photoIndex,
        severity: RuleSeverity.warning,
        action: actionFor('batch / lot panel (close-up)'),
      ));
    } else {
      results.add(RuleResult(
        code: 'LM-R6-BATCH',
        title: 'Batch / lot / code',
        clause: 'Traceability (with Rule 6(1)(d))',
        field: 'batch',
        status: RuleStatus.warning,
        message:
            'Not detected — batch/lot/code aids recalls; add if applicable.',
        severity: RuleSeverity.warning,
      ));
    }

    // ---- 9. FSSAI (food only) ----
    if (category == ProductCategory.food) {
      final fssai = d.fssai;
      if (fssai.isFound) {
        results.add(RuleResult(
          code: 'LM-FOOD-FSSAI',
          title: 'FSSAI licence number',
          clause: 'FSS Act (food labels)',
          field: 'fssai',
          status: RuleStatus.pass,
          message: '14-digit FSSAI Lic. No. found.',
          evidence: fssai.evidenceText,
          photoIndex: fssai.photoIndex,
          severity: RuleSeverity.info,
        ));
      } else {
        final st = absent(fssai);
        results.add(RuleResult(
          code: 'LM-FOOD-FSSAI',
          title: 'FSSAI licence number',
          clause: 'FSS Act (food labels)',
          field: 'fssai',
          status: st,
          message: st == RuleStatus.fail
              ? 'Missing — 14-digit FSSAI Lic. No. not detected (food category).'
              : absentMsg('FSSAI licence number'),
          severity: RuleSeverity.error,
          action:
              st == RuleStatus.fail ? null : actionFor('FSSAI licence block'),
        ));
      }
    }

    // ---- 10. Capture quality (context for every UNVERIFIED above) ----
    if (quality.meanConfidence > 0 && quality.meanConfidence < 0.5) {
      results.add(RuleResult(
        code: 'LM-READ-QUALITY',
        title: 'Capture quality (OCR confidence)',
        clause: 'Legibility requirement (proxy)',
        field: 'readability',
        status: RuleStatus.unverified,
        message:
            'Low OCR confidence (${(quality.meanConfidence * 100).toStringAsFixed(0)}%) — UNVERIFIED items above reflect capture limits, not proven violations. Retake flat, fill frame, avoid glare.',
        evidence:
            'meanConfidence=${quality.meanConfidence.toStringAsFixed(2)}',
        severity: RuleSeverity.warning,
      ));
    } else if (quality.meanConfidence > 0 && quality.meanConfidence < 0.65) {
      results.add(RuleResult(
        code: 'LM-READ-QUALITY',
        title: 'Capture quality (OCR confidence)',
        clause: 'Legibility requirement (proxy)',
        field: 'readability',
        status: RuleStatus.warning,
        message:
            'Medium confidence (${(quality.meanConfidence * 100).toStringAsFixed(0)}%) — readable, but a sharper photo would firm up the UNVERIFIED items.',
        severity: RuleSeverity.warning,
      ));
    }

    // ---- 11. Font size: manual-review gate (honest — see file docs) ----
    results.add(const RuleResult(
      code: 'LM-R7-FONT',
      title: 'Declaration font size (R7 table)',
      clause: 'PCR Rule 7 schedule',
      field: 'fontSize',
      status: RuleStatus.manualReview,
      message:
          'Cannot be measured from pixels alone — place a ruler/scale card next to the smallest declaration, compare against the R7 table (≤100cm²→1mm, 100–500→2mm, 500–2500→4mm, >2500→6mm), then confirm here.',
      severity: RuleSeverity.warning,
    ));

    // ---- score + verdict ----
    var score = 100;
    for (final r in results) {
      if (r.status == RuleStatus.fail) {
        score -= r.severity == RuleSeverity.error ? 15 : 10;
      } else if (r.status == RuleStatus.warning) {
        score -= 5;
      } else if (r.status == RuleStatus.unverified) {
        score -= 5;
      } else if (r.status == RuleStatus.manualReview) {
        score -= 3;
      }
    }
    score = score.clamp(0, 100);

    final hasFail = results.any((r) => r.status == RuleStatus.fail);
    final hasAttention = results.any((r) =>
        r.status == RuleStatus.warning ||
        r.status == RuleStatus.manualReview ||
        r.status == RuleStatus.unverified);
    final verdict = hasFail
        ? Verdict.nonCompliant
        : (hasAttention ? Verdict.needsReview : Verdict.compliant);

    return ComplianceReport(
      verdict: verdict,
      score: score,
      results: results,
      declarations: d,
      category: category,
      checkedAt: DateTime.now(),
      meanConfidence: quality.meanConfidence,
      regionCount: quality.regionCount,
      photoCount: quality.photoCount,
      combinedText: combinedText,
      quality: quality,
    );
  }

  RuleResult _dateRule(
    FieldObservation o,
    String code,
    String title,
    String clause,
    ExtractionQuality quality,
    String? action, {
    required bool missingIsFail,
  }) {
    if (o.isFound) {
      return RuleResult(
        code: code,
        title: title,
        clause: clause,
        field: code == 'LM-R6-DATE-MFG' ? 'mfgDate' : 'expDate',
        status: RuleStatus.pass,
        message:
            'Date found${o.method == ExtractMethod.variablePrintPipeline ? ' (dot-matrix re-read)' : ''}.',
        evidence:
            '${o.evidenceLabel != null ? '${o.evidenceLabel}: ' : ''}${o.evidenceText}',
        photoIndex: o.photoIndex,
        severity: RuleSeverity.info,
      );
    }
    if (o.status == FieldStatus.unverified) {
      return RuleResult(
        code: code,
        title: title,
        clause: clause,
        field: code == 'LM-R6-DATE-MFG' ? 'mfgDate' : 'expDate',
        status: RuleStatus.unverified,
        message: o.note ?? 'Date label glimpsed but unreadable.',
        evidence: o.evidenceText,
        photoIndex: o.photoIndex,
        severity: RuleSeverity.warning,
        action: action,
      );
    }
    if (!missingIsFail) {
      return RuleResult(
        code: code,
        title: title,
        clause: clause,
        field: 'expDate',
        status: RuleStatus.warning,
        message:
            'Not detected — add expiry/best-before for food/perishables; at minimum confirm it is exempt.',
        severity: RuleSeverity.warning,
      );
    }
    final adequate = quality.adequate;
    return RuleResult(
      code: code,
      title: title,
      clause: clause,
      field: 'mfgDate',
      status: adequate ? RuleStatus.fail : RuleStatus.unverified,
      message: adequate
          ? 'Missing — month and year of manufacture/packing/import.'
          : 'Could not verify — month/year of manufacture/packing/import not detected and the capture is too weak to prove absence.',
      severity: RuleSeverity.error,
      action: adequate ? null : action,
    );
  }

  static bool _taxPhrasePresent(String text) => RegExp(
          r'inclusive\s+of\s+all\s+taxes?',
          caseSensitive: false)
      .hasMatch(text);

  static int _countMrpMentions(String text) {
    if (text.isEmpty) return 0;
    return RegExp(r'(maximum\s+retail\s+price|\bmrp\b|m\s*\.\s*r\s*\.\s*p\s*\.?)',
            caseSensitive: false)
        .allMatches(text)
        .length;
  }

  static String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
