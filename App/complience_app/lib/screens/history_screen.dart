import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/export_service.dart';
import '../services/ocr_store.dart';
import 'compliance_report_screen.dart';
import 'result_screen.dart';

/// Saved products + scan history (offline repository).
///
/// Tab 1 — **Products**: one row per product scan (multi-photo compliance
/// report). Tap opens the full [ComplianceReportScreen]; swipe deletes.
/// The download icon exports ALL saved products to one CSV file that opens
/// in Excel / Sheets (see [ExportService]).
///
/// Tab 2 — **Old scans**: legacy single-photo OCR texts from before the
/// compliance workflow (kept so no data is lost).
///
/// TODO(BACKEND-E): add server search (`GET /api/scans?q=`) here alongside
/// the local list once the dashboard backend exists. The local filter below
/// already matches that API's `q` + `verdict` semantics.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<ProductScanRecord>> _productsFuture;
  late Future<List<OcrRecord>> _legacyFuture;
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _search.addListener(() {
      if (mounted) setState(() => _query = _search.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _productsFuture = OcrStore.instance.listProductScans();
      _legacyFuture = OcrStore.instance.listRecent();
    });
  }

  Future<void> _exportAll() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final file = await const ExportService().exportAllScansToCsv();
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Product compliance export (CSV)',
          text:
              'All saved product scans — opens in Excel / Google Sheets.',
        ),
      );
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Saved products'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Products', icon: Icon(Icons.inventory_2_outlined)),
              Tab(text: 'Old scans', icon: Icon(Icons.text_snippet_outlined)),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Export all products (Excel-compatible CSV)',
              icon: _exporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_outlined),
              onPressed: _exporting ? null : _exportAll,
            ),
          ],
        ),
        body: TabBarView(
          children: [
            _productsTab(context),
            _legacyTab(context),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ products ---

  Widget _productsTab(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Search products',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<ProductScanRecord>>(
            future: _productsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return _errorBody('Could not load products:\n${snapshot.error}');
              }
              var records = snapshot.data ?? const <ProductScanRecord>[];
              if (_query.isNotEmpty) {
                records = records
                    .where((r) =>
                        r.productName.toLowerCase().contains(_query) ||
                        r.verdict.toLowerCase().contains(_query) ||
                        r.category.toLowerCase().contains(_query))
                    .toList();
              }
              if (records.isEmpty) {
                return Center(
                  child: Text(
                    _query.isEmpty
                        ? 'No products yet.\nScan a product to save its report here.'
                        : 'No products match "$_query".',
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return RefreshIndicator(
                onRefresh: () async => _refresh(),
                child: ListView.separated(
                  itemCount: records.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final r = records[i];
                    return Dismissible(
                      key: ValueKey('product-${r.id}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Theme.of(context).colorScheme.error,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete_outline,
                            color: Colors.white),
                      ),
                      onDismissed: (_) async {
                        if (r.id != null) {
                          await OcrStore.instance.deleteProductScan(r.id!);
                        }
                        _refresh();
                      },
                      child: ListTile(
                        leading: _thumb(r),
                        title: Text(
                          r.productName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${_verdictLabel(r.verdict)} • ${r.score}/100 • '
                          '${r.photoCount} photo${r.photoCount == 1 ? '' : 's'} • '
                          '${_formatDate(r.createdAt)}',
                        ),
                        trailing: _verdictDot(r.verdict),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ComplianceReportScreen(
                                record: r,
                              ),
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
        ),
      ],
    );
  }

  Widget _thumb(ProductScanRecord r) {
    final first = r.imagePaths.isEmpty ? null : r.imagePaths.first;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 52,
        height: 52,
        child: first != null && File(first).existsSync()
            ? Image.file(File(first),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.image_outlined))
            : const Icon(Icons.image_outlined),
      ),
    );
  }

  Widget _verdictDot(String verdict) {
    final color = switch (verdict) {
      'compliant' => Colors.green.shade700,
      'nonCompliant' => Colors.red.shade700,
      _ => Colors.amber.shade800,
    };
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  String _verdictLabel(String verdict) => switch (verdict) {
        'compliant' => 'Compliant',
        'nonCompliant' => 'Non-compliant',
        _ => 'Needs review',
      };

  // ------------------------------------------------------------- legacy ---

  Widget _legacyTab(BuildContext context) {
    return FutureBuilder<List<OcrRecord>>(
      future: _legacyFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _errorBody('Could not load old scans:\n${snapshot.error}');
        }
        final records = snapshot.data ?? const <OcrRecord>[];
        if (records.isEmpty) {
          return const Center(child: Text('No old single-photo scans.'));
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
                  if (r.id != null) {
                    await OcrStore.instance.delete(r.id!);
                  }
                  _refresh();
                },
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 52,
                      height: 52,
                      child: File(r.imagePath).existsSync()
                          ? Image.file(File(r.imagePath),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.image_outlined))
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
    );
  }

  Widget _errorBody(String msg) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(msg, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _refresh,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.day}/${dt.month}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }
}
