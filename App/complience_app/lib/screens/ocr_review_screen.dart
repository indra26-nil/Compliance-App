import 'dart:io';

import 'package:flutter/material.dart';

import '../services/ocr_postprocess.dart';
import '../services/rule_engine.dart';
import '../services/scan_pipeline.dart';
import 'field_review_screen.dart';

/// Stage 2 of the human-in-the-loop flow: OCR review.
///
/// The officer sees every OCR line per photo (geometry preserved
/// underneath), can fix garble by hand or tap auto-clean, then picks HOW
/// lines become declarations before any extraction runs:
///
/// * [ExtractionMode.regex] — auto formatting with rules only (fastest).
/// * [ExtractionMode.assisted] — on-device text model rescues garbled
///   labels; regexes stay as validators (never deciders).
/// * [ExtractionMode.ensemble] — runs both, keeps the best of each field.
///
/// Line edits rebuild layouts with identical boxes ([ScanPipeline.applyLineEdits]),
/// so spatial extraction keeps working on corrected text.
class OcrReviewScreen extends StatefulWidget {
  const OcrReviewScreen({
    super.key,
    required this.ocr,
    this.productName = '',
    this.category = ProductCategory.general,
  });

  final OcrBundle ocr;
  final String productName;
  final ProductCategory category;

  @override
  State<OcrReviewScreen> createState() => _OcrReviewScreenState();
}

class _OcrReviewScreenState extends State<OcrReviewScreen> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _originals = {};
  late ExtractionMode _mode;
  bool _modeTouched = false;
  bool _ready = false;
  bool _warming = false;
  bool _working = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    for (final layout in widget.ocr.layouts) {
      for (var li = 0; li < layout.lines.length; li++) {
        final key = '${layout.photoIndex}:$li';
        final text = layout.lines[li].text;
        _originals[key] = text;
        _controllers[key] = TextEditingController(text: text);
      }
    }
    // Prefer smart assist when its model is actually ready on this device;
    // otherwise regex (assist would only fall back anyway). Warm-up may
    // still be finishing while the officer reviews lines — refresh when
    // it lands (without overriding an explicit mode pick).
    _ready = ScanPipeline.isClassifierReady;
    _mode =
        _ready ? ExtractionMode.assisted : ExtractionMode.regex;
    ScanPipeline.warmUpClassifier().then((_) {
      if (!mounted) return;
      setState(() {
        _ready = ScanPipeline.isClassifierReady;
        if (_ready && !_modeTouched) _mode = ExtractionMode.assisted;
      });
    });
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _cleanPhoto(int photoIndex, int lineCount) {
    setState(() {
      for (var li = 0; li < lineCount; li++) {
        final c = _controllers['$photoIndex:$li'];
        if (c != null) c.text = OcrPostprocess.cleanLine(c.text);
      }
    });
  }

  void _cleanAll() {
    setState(() {
      for (final c in _controllers.values) {
        c.text = OcrPostprocess.cleanLine(c.text);
      }
    });
  }

  int get _editedCount {
    var n = 0;
    _controllers.forEach((key, c) {
      if (c.text != _originals[key]) n++;
    });
    return n;
  }

  Future<void> _retryClassifier() async {
    if (_warming) return;
    setState(() => _warming = true);
    await ScanPipeline.retryClassifier();
    if (!mounted) return;
    setState(() {
      _warming = false;
      _ready = ScanPipeline.isClassifierReady;
      if (_ready && !_modeTouched) _mode = ExtractionMode.assisted;
    });
  }

  Future<void> _continue() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final edits = <String, String>{};
      _controllers.forEach((key, c) {
        if (c.text != _originals[key]) edits[key] = c.text;
      });
      final pending = await const ScanPipeline().extractWithMode(
        ocr: widget.ocr,
        productName: widget.productName,
        category: widget.category,
        mode: _mode,
        lineEdits: edits,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FieldReviewScreen(pending: pending, ocr: widget.ocr),
        ),
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
    final ready = _ready;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review OCR text'),
        actions: [
          TextButton(
            onPressed: _working ? null : _cleanAll,
            child: const Text('Auto-clean all'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Fix misread lines before extraction. What you approve '
                    'here is what the field finder sees — boxes stay the same, '
                    'only text changes.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                  if (!ready) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Smart assist unavailable: '
                              '${ScanPipeline.classifierStatus()} '
                              'Smart assist / Ensemble will fall back to '
                              'regex-only with a note.',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          TextButton(
                            onPressed:
                                _warming ? null : _retryClassifier,
                            child: Text(
                                _warming ? 'Retrying…' : 'Retry'),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  for (final layout in widget.ocr.layouts) ...[
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(widget.ocr.imagePaths[layout.photoIndex]),
                            height: 56,
                            width: 56,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox(
                              height: 56,
                              width: 56,
                              child: Icon(Icons.image_outlined),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Photo ${layout.photoIndex + 1} — '
                            '${layout.lines.length} lines',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        TextButton(
                          onPressed: _working
                              ? null
                              : () => _cleanPhoto(layout.photoIndex,
                                  layout.lines.length),
                          child: const Text('Auto-clean'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    for (var li = 0;
                        li < layout.lines.length;
                        li++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: TextField(
                          controller:
                              _controllers['${layout.photoIndex}:$li'],
                          enabled: !_working,
                          maxLines: null,
                          minLines: 1,
                          style: const TextStyle(fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true,
                            border: const OutlineInputBorder(),
                            labelText: 'L${li + 1}',
                            labelStyle: TextStyle(
                              color: (_controllers[
                                                  '${layout.photoIndex}:$li']
                                              ?.text !=
                                          _originals[
                                              '${layout.photoIndex}:$li'])
                                  ? colorScheme.primary
                                  : colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                  ],
                  const Divider(),
                  Text(
                    'How should lines become declarations?',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  for (final m in ExtractionMode.values)
                    RadioListTile<ExtractionMode>(
                      value: m,
                      groupValue: _mode,
                      onChanged: _working
                          ? null
                          : (v) {
                              if (v != null) {
                                setState(() {
                                  _mode = v;
                                  _modeTouched = true;
                                });
                              }
                            },
                      title: Text(m.title),
                      subtitle: Text(m.subtitle),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Extraction failed:\n$_error',
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
                        : const Icon(Icons.arrow_forward),
                    label: Text(_working
                        ? 'Extracting…'
                        : 'Continue to fields${_editedCount > 0 ? ' ($_editedCount edited)' : ''}'),
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
