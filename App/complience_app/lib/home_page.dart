import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'screens/history_screen.dart';
import 'screens/processing_screen.dart';
import 'screens/server_settings_screen.dart';
import 'services/ocr_service.dart';
import 'services/rule_engine.dart';
import 'services/scan_pipeline.dart';

/// Home page: multi-photo product scan setup (offline-first).
///
/// One product = 1..N label photos (front + back + sides + MRP close-up).
/// The extractor merges declarations across photos (best-confidence-wins),
/// so more angles = fewer false "missing" violations.
///
/// Flow: enter product name + category -> add photos -> "Scan" ->
/// [ProcessingScreen] (staged loader) -> report card (auto-saved to
/// `product_scans`, viewable in [HistoryScreen]).
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();
  final List<XFile> _photos = [];
  ProductCategory _category = ProductCategory.general;
  bool _isPicking = false;
  bool _isConfirming = false;

  @override
  void initState() {
    super.initState();
    // Start copying models + loading the native engine early so the first
    // scan doesn't pay the full ~1-2s init cost.
    OcrService.instance.warmUp().ignore();
    // Smart-assist text model warms in the background (best-effort, pure
    // Dart): weights parse once so the first scan pays no extra cost.
    // Falls back to regex-only extraction when unavailable.
    ScanPipeline.warmUpClassifier().ignore();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickGallery() async {
    if (_isPicking) return;
    setState(() => _isPicking = true);
    try {
      // Multi-select: front + back + sides in one go.
      final images = await _picker.pickMultiImage(
        maxWidth: 3000,
        maxHeight: 3000,
        imageQuality: 95,
      );
      if (images.isNotEmpty && mounted) {
        setState(() => _photos.addAll(images));
      }
    } catch (error) {
      _snack('Could not get photos: $error', isError: true);
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<void> _pickCamera() async {
    if (_isPicking) return;
    setState(() => _isPicking = true);
    try {
      final image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 3000,
        maxHeight: 3000,
        imageQuality: 95,
      );
      if (image != null && mounted) {
        setState(() => _photos.add(image));
      }
    } catch (error) {
      _snack('Could not capture photo: $error', isError: true);
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor:
            isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _startScan() async {
    if (_photos.isEmpty || _isConfirming) return;
    if (!mounted) return;
    // Push immediately — no heavy work here, so no freeze. All OCR work is
    // deferred until ProcessingScreen has painted (see its _scheduleRun).
    setState(() => _isConfirming = true);
    try {
      final saved = await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ProcessingScreen(
            imagePaths: _photos.map((e) => e.path).toList(),
            productName: _nameController.text,
            category: _category,
          ),
        ),
      );
      // Report screen pops `true` when a scan was saved -> reset for the
      // next product. System-back (null) keeps the setup intact.
      if (saved == true && mounted) {
        setState(() {
          _photos.clear();
          _nameController.clear();
        });
        _snack('Scan saved — ready for the next product.');
      }
    } finally {
      if (mounted) setState(() => _isConfirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compliance App'),
        centerTitle: true,
        backgroundColor: colorScheme.inversePrimary,
        actions: [
          IconButton(
            tooltip: 'Server & sync',
            icon: const Icon(Icons.cloud_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const ServerSettingsScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Saved products & export',
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Product name (e.g. Potato Chips 73g)',
                prefixIcon: Icon(Icons.inventory_2_outlined),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ProductCategory>(
              value: _category,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Category',
                prefixIcon: Icon(Icons.category_outlined),
              ),
              items: const [
                DropdownMenuItem(
                  value: ProductCategory.general,
                  child: Text('General'),
                ),
                DropdownMenuItem(
                  value: ProductCategory.food,
                  child: Text('Food (adds FSSAI check)'),
                ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _category = v);
              },
            ),
            const SizedBox(height: 16),
            if (_photos.isEmpty) ...[
              _OptionCard(
                icon: Icons.photo_camera_outlined,
                title: 'Capture Photos',
                subtitle: 'Take label photos one by one (front, back, MRP)',
                iconColor: colorScheme.primary,
                onTap: _isPicking ? null : _pickCamera,
              ),
              const SizedBox(height: 12),
              _OptionCard(
                icon: Icons.photo_library_outlined,
                title: 'Upload Photos',
                subtitle: 'Select one or more existing photos',
                iconColor: colorScheme.secondary,
                onTap: _isPicking ? null : _pickGallery,
              ),
              if (_isPicking) ...[
                const SizedBox(height: 20),
                const Center(child: CircularProgressIndicator()),
              ],
            ] else ...[
              Row(
                children: [
                  Text(
                    '${_photos.length} photo${_photos.length == 1 ? '' : 's'} added',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _isPicking ? null : _pickCamera,
                    icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                    label: const Text('Add'),
                  ),
                  TextButton.icon(
                    onPressed: _isPicking ? null : _pickGallery,
                    icon: const Icon(Icons.add_photo_alternate_outlined,
                        size: 18),
                    label: const Text('Gallery'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: _photos.length,
                itemBuilder: (context, i) => Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(
                        File(_photos[i].path),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color:
                              colorScheme.surfaceContainerHighest,
                          alignment: Alignment.center,
                          child: Text(
                            '${i + 1}',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 2,
                      top: 2,
                      child: InkWell(
                        onTap: () =>
                            setState(() => _photos.removeAt(i)),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close,
                              color: Colors.white, size: 16),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Tip: include the principal panel, MRP close-up, dates and '
                'consumer-care block. Anything found on ANY photo counts.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: (_isConfirming || _isPicking) ? null : _startScan,
                icon: _isConfirming
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child:
                            CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.document_scanner_outlined),
                label: Text(_isConfirming
                    ? 'Opening…'
                    : 'Scan ${_photos.length} photo${_photos.length == 1 ? '' : 's'}'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: (_isPicking || _isConfirming)
                    ? null
                    : () => setState(_photos.clear),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear photos'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A tappable card representing one of the two photo-source options.
class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color iconColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 34, color: iconColor),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
