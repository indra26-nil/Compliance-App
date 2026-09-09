import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/ocr_service.dart';
import '../services/rule_engine.dart';
import '../services/scan_pipeline.dart';
import 'ocr_review_screen.dart';

/// Multi-photo product scan loader (stage 1: OCR only).
///
/// Flow: HomePage "Scan N photos" → here (instant navigation + staged
/// checklist with per-photo progress) → [OcrReviewScreen] (officer cleans
/// lines + picks the extraction mode) → field review → report card
/// (auto-saved to `product_scans`).
///
/// Heavy work is deferred until after the first frame + route transition
/// paints ([_scheduleRun]), OCR pre-processing runs on a background isolate,
/// and photos are OCR'd sequentially with progress callbacks — so adding
/// more photos never freezes the previous page.
///
/// On desktop/web (no OCR backend) a clear message is shown instead of a
/// crash. On failure shows the error with Retry.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({
    super.key,
    required this.imagePaths,
    this.productName = '',
    this.category = ProductCategory.general,
  }) : assert(imagePaths.length > 0, 'Need at least one photo.');

  /// Local paths of the 1..N label photos (same product).
  final List<String> imagePaths;
  final String productName;
  final ProductCategory category;

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingStep {
  const _ProcessingStep(this.title, this.subtitle, this.icon);

  final String title;
  final String subtitle;
  final IconData icon;
}

const _steps = <_ProcessingStep>[
  _ProcessingStep(
    'Scanning photos',
    'Reading each label on-device (offline)',
    Icons.document_scanner_outlined,
  ),
  _ProcessingStep(
    'Extracting declarations',
    'Finding MRP, net qty, dates + re-reading small print',
    Icons.manage_search_outlined,
  ),
  _ProcessingStep(
    'Checking LM-PCR rules',
    'Validating against 2011 requirements',
    Icons.rule_outlined,
  ),
  _ProcessingStep(
    'Saving product',
    'Storing report to product history',
    Icons.save_outlined,
  ),
];

class _ProcessingScreenState extends State<ProcessingScreen> {
  Object? _error;
  bool _running = true;
  int _currentStep = 0;
  int _photoDone = 0;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    // Defer ALL heavy work until after this screen has painted + the push
    // transition finished. Starting OCR synchronously in initState blocks
    // the UI thread during the transition ("app freezes on scan").
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRun());
  }

  Future<void> _scheduleRun() async {
    if (_started || !mounted) return;
    _started = true;
    // Let the route transition (~300ms) + first loading frame paint before
    // touching disk / isolates / the native engine.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    await _run();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _currentStep = 0;
      _photoDone = 0;
    });
    try {
      if (kIsWeb) {
        throw UnsupportedError(
            'Web OCR needs paddleocr-js bundling (see plugin README). '
            'Run on Android for the offline ONNX pipeline.');
      }
      if (!(Platform.isAndroid || Platform.isIOS)) {
        throw UnsupportedError(
            'Offline OCR is supported on Android/iOS only in this build. '
            'Run on an Android device (arm64, API 24+).');
      }

      final ocr = await const ScanPipeline().ocrPhotos(
        imagePaths: widget.imagePaths,
        onPhotoProgress: (done, total) {
          if (!mounted) return;
          setState(() => _photoDone = done);
        },
      );
      if (!mounted) return;
      // Replace loader with OCR review. Field review + report card follow;
      // the report pops `true` so HomePage (the original pusher) knows a
      // scan was saved and can reset for the next product.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => OcrReviewScreen(
            ocr: ocr,
            productName: widget.productName,
            category: widget.category,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final name = widget.productName.trim().isEmpty
        ? 'Unnamed product'
        : widget.productName.trim();

    return Scaffold(
      appBar: AppBar(
        title: Text(_running ? 'Scanning $name…' : 'Scan failed'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SizedBox(
              height: 140,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.imagePaths.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) => Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(widget.imagePaths[i]),
                        height: 140,
                        width: 140,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox(
                          height: 140,
                          width: 140,
                          child: Center(
                              child:
                                  Icon(Icons.image_outlined, size: 40)),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${i + 1}/${widget.imagePaths.length}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (_running) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              if (widget.imagePaths.length > 1 && _currentStep == 0)
                Text(
                  'Scanning photo $_photoDone/${widget.imagePaths.length}…',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              const SizedBox(height: 12),
              ...List.generate(_steps.length, (i) {
                final step = _steps[i];
                final done = i < _currentStep;
                final active = i == _currentStep;
                return _StepRow(
                  step: step,
                  done: done,
                  active: active,
                );
              }),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: OcrService.instance.status,
                builder: (_, status, __) => Text(
                  status,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'First scan loads the offline AI models (a few seconds); '
                  'later scans are faster. Declarations found on ANY photo '
                  'count toward compliance.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ] else ...[
              Icon(
                Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                'Scan failed:\n$_error',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _run,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back to photos'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.done,
    required this.active,
  });

  final _ProcessingStep step;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final Widget leading;
    if (done) {
      leading = Icon(Icons.check_circle, color: colorScheme.primary);
    } else if (active) {
      leading = const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    } else {
      leading = Icon(
        Icons.circle_outlined,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      );
    }

    return Opacity(
      opacity: done || active ? 1.0 : 0.55,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 14),
            Icon(step.icon,
                size: 22,
                color: active
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.title,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight:
                          active ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                  Text(
                    step.subtitle,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
