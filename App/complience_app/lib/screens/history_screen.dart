import 'dart:io';

import 'package:flutter/material.dart';

import '../services/ocr_store.dart';
import 'result_screen.dart';

/// List of past scans with thumbnails. Tap to view/edit, swipe to delete.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<OcrRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = OcrStore.instance.listRecent();
  }

  void _refresh() {
    setState(() {
      _future = OcrStore.instance.listRecent();
    });
  }

  String _formatDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.day}/${dt.month}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan history')),
      body: FutureBuilder<List<OcrRecord>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Could not load history:\n${snapshot.error}'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _refresh,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }
          final records = snapshot.data ?? const <OcrRecord>[];
          if (records.isEmpty) {
            return const Center(
              child: Text('No scans yet.\nCapture a photo to get started.'),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView.separated(
              itemCount: records.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final r = records[i];
                final preview = r.extractedText.trim().isEmpty
                    ? '(no text detected)'
                    : r.extractedText.trim().split('\n').first;
                return Dismissible(
                  key: ValueKey('ocr-${r.id}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Theme.of(context).colorScheme.error,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete_outline,
                        color: Colors.white),
                  ),
                  onDismissed: (_) async {
                    if (r.id != null) await OcrStore.instance.delete(r.id!);
                    _refresh();
                  },
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: File(r.imagePath).existsSync()
                            ? Image.file(File(r.imagePath), fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(
                                    Icons.image_outlined))
                            : const Icon(Icons.image_outlined),
                      ),
                    ),
                    title: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(_formatDate(r.createdAt)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ResultScreen(record: r),
                        ),
                      );
                      _refresh();
                    },
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
