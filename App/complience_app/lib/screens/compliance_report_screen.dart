import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/backend_api.dart';
import '../services/export_service.dart';
import '../services/field_extractor.dart';
import '../services/ocr_store.dart';
import '../services/rule_engine.dart';
import '../services/sync_service.dart';

/// Report card for one saved product scan (the compliance verdict screen).
///
/// Used in two ways:
/// 1. Fresh: pushed by [ProcessingScreen] right after a scan (`isFreshScan`
///    = true). "Done" pops `true` so HomePage resets for the next product.
/// 2. History: opened from [HistoryScreen] for any saved product. "Done"
///    becomes a normal back navigation.
///
/// Everything renders from the stored [ProductScanRecord.reportJson] —
/// no re-OCR needed, fully offline.
///
/// TODO(BACKEND-F): wired — the action below downloads the signed server
/// copy via `BackendApi.downloadReportPdf(serverId)`. The sections above
/// (verdict, violations, evidence photos) already match that PDF's layout.
class ComplianceReportScreen extends StatefulWidget {
  const ComplianceReportScreen({
    super.key,
    required this.record,
    this.isFreshScan = false,
  });

  final ProductScanRecord record;
  final bool isFreshScan;

  @override
  State<ComplianceReportScreen> createState() =>
      _ComplianceReportScreenState();
}

class _ComplianceReportScreenState extends State<ComplianceReportScreen> {
  late ProductScanRecord _record;
  ComplianceReport? _report;
  bool _sharing = false;
  bool _pdfBusy = false;
  bool _syncBusy = false;

  @override
  void initState() {
    super.initState();
    _record = widget.record;
    try {
      _report = ComplianceReport.fromJson(_record.reportJson);
    } catch (_) {
      _report = null;
    }
  }

  Future<void> _rename() async {
    final controller =
        TextEditingController(text: _record.productName);
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename product'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Product name',
          ),
          onSubmitted: (_) =>
              Navigator.of(context).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (next == null || next.isEmpty || next == _record.productName) return;
    final id = _record.id;
    if (id != null) {
      await OcrStore.instance.updateProductScanName(id, next);
      final refreshed = await OcrStore.instance.getProductScan(id);
      if (refreshed != null && mounted) {
        setState(() => _record = refreshed);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Product renamed')),
        );
      }
    }
  }

  Future<void> _shareCsv() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final file =
          await const ExportService().exportSingleScanToCsv(_record);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Compliance report — ${_record.productName}',
          text: 'Compliance report for ${_record.productName} '
              '(${_record.verdict}, ${widget.record.score}/100). '
              'Opens in Excel / Sheets.',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not export: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _downloadPdf() async {
    if (_pdfBusy) return;
    setState(() => _pdfBusy = true);
    try {
      var serverId = _record.serverId;
      if (serverId == null || serverId.isEmpty) {
        // Try a sync pass first (officer may have just signed in).
        setState(() => _syncBusy = true);
        try {
          await SyncService.instance.syncNow();
        } finally {
          if (mounted) setState(() => _syncBusy = false);
        }
        final id = _record.id;
        if (id != null) {
          final refreshed = await OcrStore.instance.getProductScan(id);
          if (refreshed != null && mounted) {
            setState(() => _record = refreshed);
            serverId = refreshed.serverId;
          }
        }
      }
      if (serverId == null || serverId.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Not on the server yet — sign in under Server & sync, then Sync now.'),
          ),
        );
        return;
      }
      final bytes = await BackendApi.instance.downloadReportPdf(serverId);
      final file = await const ExportService()
          .writeBytesForShare(bytes, 'compliance-$serverId.pdf');
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Official compliance report — ${_record.productName}',
          text: 'Signed archival copy from the server.',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not fetch official PDF: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pdfBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final report = _report;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _record.productName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Rename product',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _rename,
          ),
          IconButton(
            tooltip: 'Share this report (CSV)',
            icon: _sharing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.share_outlined),
            onPressed: _sharing ? null : _shareCsv,
          ),
          IconButton(
            tooltip: 'Official PDF from server (F)',
            icon: _pdfBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _pdfBusy ? null : _downloadPdf,
          ),
        ],
      ),
      body: SafeArea(
        child: report == null
            ? _corruptBody(context)
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _VerdictBanner(record: _record, report: report),
                  const SizedBox(height: 8),
                  _SyncChip(record: _record, syncing: _syncBusy),
                  const SizedBox(height: 12),
                  _PhotoStrip(paths: _record.imagePaths),
                  const SizedBox(height: 12),
                  _DeclarationsCard(report: report),
                  const SizedBox(height: 12),
                  _RuleList(report: report),
                  const SizedBox(height: 12),
                  ExpansionTile(
                    leading: const Icon(Icons.text_snippet_outlined),
                    title: const Text('Combined OCR text'),
                    subtitle: Text(
                      '${_record.photoCount} photo${_record.photoCount == 1 ? '' : 's'} • '
                      '${(report.meanConfidence * 100).toStringAsFixed(0)}% confidence',
                    ),
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectableText(
                          _record.ocrText.isEmpty
                              ? '(no text recognised)'
                              : _record.ocrText,
                          style:
                              Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context)
                        .pop(widget.isFreshScan ? true : null),
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(widget.isFreshScan
                        ? 'Done — back to scanner'
                        : 'Back to products'),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _corruptBody(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Icon(Icons.warning_amber_outlined, size: 48),
        const SizedBox(height: 12),
        const Text(
          'This saved scan has no readable report data, but the raw OCR '
          'text below was preserved.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        SelectableText(_record.ocrText),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back'),
        ),
      ],
    );
  }
}

/// Server sync status for one saved scan (D).
class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.record, required this.syncing});

  final ProductScanRecord record;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    final synced = record.synced && (record.serverId?.isNotEmpty ?? false);
    final (icon, label) = syncing
        ? (Icons.sync_outlined, 'Syncing to server…')
        : synced
            ? (Icons.cloud_done_outlined, 'Synced to server')
            : (Icons.cloud_off_outlined,
                'On this device only — sign in & sync to file it');
    return Row(
      children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.secondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.record, required this.report});

  final ProductScanRecord record;
  final ComplianceReport report;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (bg, fg, label, icon) = switch (report.verdict) {
      Verdict.compliant => (
          Colors.green.shade700,
          Colors.white,
          'COMPLIANT',
          Icons.verified_outlined
        ),
      Verdict.nonCompliant => (
          colorScheme.error,
          colorScheme.onError,
          'NON-COMPLIANT',
          Icons.cancel_outlined
        ),
      Verdict.needsReview => (
          Colors.amber.shade700,
          Colors.white,
          'NEEDS REVIEW',
          Icons.warning_amber_outlined
        ),
    };

    return Card(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: fg, size: 40),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(
                          color: fg,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Score ${report.score}/100 • '
                    '${report.failCount} fail • '
                    '${report.unverifiedCount} unverified • '
                    '${report.warningCount} warning • '
                    '${report.reviewCount} review',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: fg.withValues(alpha: 0.9)),
                  ),
                  Text(
                    '${record.category} • ${record.photoCount} photo${record.photoCount == 1 ? '' : 's'} • ${_date(record.createdAt)}',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: fg.withValues(alpha: 0.85)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _date(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.day}/${dt.month}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({required this.paths});

  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    if (paths.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: paths.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) => Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                File(paths[i]),
                height: 92,
                width: 92,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  height: 92,
                  width: 92,
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                  alignment: Alignment.center,
                  child:
                      const Icon(Icons.image_outlined, size: 32),
                ),
              ),
            ),
            Positioned(
              left: 5,
              bottom: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeclarationsCard extends StatelessWidget {
  const _DeclarationsCard({required this.report});

  final ComplianceReport report;

  @override
  Widget build(BuildContext context) {
    final d = report.declarations;
    String photoRef(FieldObservation o) =>
        ' — evidence photo ${o.photoIndex + 1}';
    final rows = <(String, FieldObservation, String?)>[
      ('Generic name', d.genericName, null),
      ('Brand', d.brand, null),
      (
        'Net quantity',
        d.netQty,
        d.netQty.isFound ? photoRef(d.netQty) : null
      ),
      ('MRP', d.mrp, d.mrp.isFound ? photoRef(d.mrp) : null),
      ('Mfg / Pack date', d.mfg, null),
      ('Expiry / Use-by', d.exp, null),
      (
        'Manufacturer',
        d.manufacturer,
        d.manufacturer.data['role'] != null
            ? ' (${d.manufacturer.data['role']})'
            : null
      ),
      (
        'Manufacturer address',
        d.manufacturer.data['address'] != null &&
                (d.manufacturer.data['address'] as String).isNotEmpty
            ? FieldObservation(
                field: 'manufacturerAddress',
                status: d.manufacturer.status,
                value: d.manufacturer.data['address'] as String,
                fieldConfidence: d.manufacturer.fieldConfidence,
                photoIndex: d.manufacturer.photoIndex,
              )
            : FieldObservation.missing('manufacturerAddress'),
        null
      ),
      ('Care phone', d.carePhone, null),
      ('Care email', d.careEmail, null),
      ('Country of origin', d.origin, null),
      ('Batch / lot', d.batch, null),
      if (report.category == ProductCategory.food)
        ('FSSAI Lic.', d.fssai, null),
      ('Ingredients', d.ingredients, null),
      ('Allergen advice', d.allergen, null),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Declarations found (${d.mergedFromPhotos} photo${d.mergedFromPhotos == 1 ? '' : 's'} merged)',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            ...rows.map((r) {
              final obs = r.$2;
              final (text, color) = switch (obs.status) {
                FieldStatus.found => (
                    '${obs.value ?? ''}${r.$3 ?? ''}',
                    null as Color?
                  ),
                FieldStatus.unverified => (
                    obs.value != null && obs.value!.isNotEmpty
                        ? '⚠ unverified: ${obs.value}'
                        : '⚠ unverified — see rule checks below',
                    Colors.amber.shade800
                  ),
                FieldStatus.notFound => (
                    '— not detected',
                    Theme.of(context).colorScheme.error
                  ),
              };
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 150,
                      child: Text(
                        r.$1,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        text,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: color,
                            ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _RuleList extends StatelessWidget {
  const _RuleList({required this.report});

  final ComplianceReport report;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Rule checks (${report.results.length})',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        ...report.results.map((r) => _RuleCard(result: r)),
      ],
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({required this.result});

  final RuleResult result;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, color, statusLabel) = switch (result.status) {
      RuleStatus.pass => (Icons.check_circle, Colors.green.shade700, 'PASS'),
      RuleStatus.fail => (Icons.cancel, colorScheme.error, 'FAIL'),
      RuleStatus.warning =>
        (Icons.warning_amber, Colors.amber.shade800, 'WARNING'),
      RuleStatus.manualReview =>
        (Icons.info_outline, Colors.blue.shade700, 'REVIEW'),
      // UNVERIFIED is visually distinct from FAIL: "could not determine"
      // is not "violated". Always paired with the recommended action.
      RuleStatus.unverified =>
        (Icons.visibility_off_outlined, Colors.deepOrange.shade700, 'UNVERIFIED'),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          result.title,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 6,
                    children: [
                      Chip(
                        label: Text(result.code,
                            style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                      Chip(
                        label: Text(result.clause,
                            style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    result.message,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (result.action != null &&
                      result.action!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Recommended: ${result.action}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: color,
                            ),
                      ),
                    ),
                  ],
                  if (result.evidence != null &&
                      result.evidence!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Evidence${result.photoIndex != null ? ' (photo ${result.photoIndex! + 1})' : ''}: ${result.evidence}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
