import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/ocr_service.dart';
import '../services/ocr_store.dart';
import 'result_screen.dart';

/// Runs OCR on [imagePath] with a spinner, then routes to [ResultScreen].
///
/// Flow: HomePage "Use This Photo" → here → ResultScreen (auto-saved).
/// On failure shows the error with a Retry button. On desktop platforms the
/// plugin has no backend — a clear message is shown instead of a crash.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key, required this.imagePath});

  final String imagePath;

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  Object? _error;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
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
      final output =
          await OcrService.instance.recognizeFile(File(widget.imagePath));
      final id = await OcrStore.instance.insert(
        imagePath: widget.imagePath,
        extractedText: output.text,
      );
      final record = await OcrStore.instance.getById(id);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            record: record ??
                OcrRecord(
                  id: id,
                  imagePath: widget.imagePath,
                  extractedText: output.text,
                  createdAt: DateTime.now(),
                ),
            regionCount: output.results.length,
            meanConfidence: output.meanConfidence,
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
    return Scaffold(
      appBar: AppBar(title: const Text('Scanning...')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(widget.imagePath),
                  height: 220,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    height: 220,
                    child: Center(child: Icon(Icons.image_outlined, size: 48)),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              if (_running) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                ValueListenableBuilder<String>(
                  valueListenable: OcrService.instance.status,
                  builder: (_, status, __) => Text(
                    status,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Running high-accuracy label scan offline on-device…\nHold steady, fill the frame, avoid glare.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
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
                  'OCR failed:\n$_error',
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
                  child: const Text('Pick another photo'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
