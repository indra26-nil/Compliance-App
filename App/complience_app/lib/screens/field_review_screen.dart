import 'package:flutter/material.dart';

import '../services/field_extractor.dart';
import '../services/scan_pipeline.dart';
import 'compliance_report_screen.dart';

/// Stage 3 of the human-in-the-loop flow: field review.
///
/// Shows every extracted declaration with its evidence status BEFORE the
/// regulation engine runs. The officer confirms or retypes values
/// (empty = clear to not-detected), then continues to rule-check + save.
/// Corrections are stamped [ExtractMethod.manualEntry] and re-parsed for
/// MRP/net-quantity so the rule engine scores the typed values.
class FieldReviewScreen extends StatefulWidget {
  const FieldReviewScreen({
    super.key,
    required this.pending,
    required this.ocr,
  });

  final PendingScan pending;
  final OcrBundle ocr;

  @override
  State<FieldReviewScreen> createState() => _FieldReviewScreenState();
}

const _editableFields = <(String, String)>[
  ('brand', 'Brand'),
  ('productName', 'Product / common name'),
  ('netQty', 'Net quantity (e.g. 80 g)'),
  ('mrp', 'MRP (e.g. Rs. 42)'),
  ('batch', 'Batch / lot / code'),
  ('mfg', 'Mfg / pack date'),
  ('exp', 'Expiry / use-by'),
  ('manufacturer', 'Manufacturer / packer / importer'),
  ('manufacturerAddress', 'Manufacturer address'),
  ('carePhone', 'Consumer-care phone'),
  ('careEmail', 'Consumer-care email'),
  ('fssai', 'FSSAI lic. no.'),
  ('origin', 'Country of origin'),
];

class _FieldReviewScreenState extends State<FieldReviewScreen> {
  final Map<String, TextEditingController> _controllers = {};
  bool _working = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.pending.product;
    for (final (key, _) in _editableFields) {
      final initial = key == 'manufacturerAddress'
          ? (p.manufacturer.data['address']?.toString() ?? '')
          : (p.fields[key]?.value ?? '');
      _controllers[key] = TextEditingController(text: initial);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  int get _changedCount {
    final p = widget.pending.product;
    var n = 0;
    for (final (key, _) in _editableFields) {
      final initial = key == 'manufacturerAddress'
          ? (p.manufacturer.data['address']?.toString() ?? '')
          : (p.fields[key]?.value ?? '');
      if ((_controllers[key]?.text ?? '') != initial) n++;
    }
    return n;
  }

  FieldStatus _statusOf(String key) {
    final p = widget.pending.product;
    if (key == 'manufacturerAddress') return p.manufacturer.status;
    return p.fields[key]?.status ?? FieldStatus.notFound;
  }

  Future<void> _continue() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final values = <String, String>{
        for (final (key, _) in _editableFields)
          key: _controllers[key]?.text ?? '',
      };
      final corrected =
          applyFieldCorrections(widget.pending.product, values);
      final outcome = await const ScanPipeline().checkAndSave(
        widget.pending,
        productOverride: corrected,
      );
      if (!mounted) return;
      // Replace the review chain with the report card (auto-saved, as before).
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => ComplianceReportScreen(
            record: outcome.record,
            isFreshScan: true,
          ),
        ),
        (route) => route.isFirst,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review declarations'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${widget.pending.mode.title} • ${widget.pending.modeNote}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Confirm each declaration before the rule check. '
                    'Retype a wrong value, or clear it to mark not-detected.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 12),
                  for (final (key, label) in _editableFields) ...[
                    Row(
                      children: [
                        _StatusDot(status: _statusOf(key)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _controllers[key],
                            enabled: !_working,
                            maxLines: null,
                            minLines: 1,
                            style: const TextStyle(fontSize: 14),
                            decoration: InputDecoration(
                              isDense: true,
                              border: const OutlineInputBorder(),
                              labelText: label,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_error != null) ...[
                    Text(
                      'Save failed:\n$_error',
                      style: TextStyle(color: colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _working ? null : _continue,
                    icon: _working
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.rule_outlined),
                    label: Text(_working
                        ? 'Checking rules…'
                        : 'Check compliance${_changedCount > 0 ? ' ($_changedCount corrected)' : ''}'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final FieldStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (color, icon) = switch (status) {
      FieldStatus.found => (Colors.green, Icons.check_circle),
      FieldStatus.unverified => (Colors.orange, Icons.error_outline),
      FieldStatus.notFound => (colorScheme.error, Icons.cancel_outlined),
    };
    return Tooltip(
      message: status.name,
      child: Icon(icon, color: color, size: 22),
    );
  }
}
