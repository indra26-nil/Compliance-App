import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ocr_store.dart';

/// Shows the extracted text for one scan, editable + auto-saved on edit.
///
/// Created by [ProcessingScreen] after OCR, or opened from history.
class ResultScreen extends StatefulWidget {
  const ResultScreen(
      {super.key, required this.record, this.regionCount, this.meanConfidence});

  final OcrRecord record;
  final int? regionCount;
  final double? meanConfidence;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  late final TextEditingController _controller;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.record.extractedText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final id = widget.record.id;
    if (id == null) return;
    setState(() => _saving = true);
    try {
      await OcrStore.instance.updateText(id, _controller.text);
      if (!mounted) return;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan result'),
        actions: [
          IconButton(
            tooltip: 'Copy text',
            icon: const Icon(Icons.copy_outlined),
            onPressed: () async {
              await Clipboard.setData(
                  ClipboardData(text: _controller.text));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')),
                );
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(widget.record.imagePath),
                height: 200,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  height: 120,
                  color: colorScheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: const Icon(Icons.image_outlined, size: 40),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (widget.regionCount != null)
              Text(
                '${widget.regionCount} text region(s) detected • offline PP-OCRv5'
                '${widget.meanConfidence != null && widget.meanConfidence! > 0 ? ' • confidence ${(widget.meanConfidence! * 100).toStringAsFixed(0)}%' : ''}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            if (widget.meanConfidence != null &&
                widget.meanConfidence! > 0 &&
                widget.meanConfidence! < 0.5)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Low confidence — retake with flat pack, fill frame, avoid glare/shadow.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              maxLines: null,
              minLines: 8,
              onChanged: (_) {
                if (!_dirty) setState(() => _dirty = true);
              },
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Extracted text (editable)',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: (_dirty && !_saving) ? _save : null,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_dirty ? 'Save changes' : 'Saved'),
            ),
          ],
        ),
      ),
    );
  }
}
