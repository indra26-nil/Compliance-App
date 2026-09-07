import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'screens/history_screen.dart';
import 'screens/processing_screen.dart';
import 'services/ocr_service.dart';

/// Home page of the app.
///
/// Presents the user with two options:
///   1. Capture a photo using the device camera.
///   2. Upload a photo from the device gallery.
///
/// Once a photo is selected, a preview is shown with actions to
/// retake/replace the photo or confirm it for the next step.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();
  XFile? _selectedImage;
  bool _isPicking = false;

  @override
  void initState() {
    super.initState();
    // Start copying models + loading the native engine early so the first
    // scan doesn't pay the full ~1-2s init cost.
    OcrService.instance.warmUp().ignore();
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_isPicking) return;
    setState(() => _isPicking = true);

    try {
      // High quality + capped resolution: nutrition / ingredient print needs
      // crisp glyphs. quality 85 added JPEG ringing the recogniser read as `'`.
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 3000,
        maxHeight: 3000,
        imageQuality: 95,
      );
      if (image != null) {
        setState(() => _selectedImage = image);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not get photo: $error'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<void> _confirmPhoto() async {
    final image = _selectedImage;
    if (image == null) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProcessingScreen(imagePath: image.path),
      ),
    );
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
            tooltip: 'Scan history',
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
        child: _selectedImage == null
            ? _buildOptionsView(context)
            : _buildPreviewView(context),
      ),
    );
  }

  /// Shown when no photo has been selected yet: the two main options.
  Widget _buildOptionsView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.document_scanner_outlined,
              size: 80,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Get Started',
              textAlign: TextAlign.center,
              style: textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Capture a new photo or upload one from your gallery\nto begin the compliance check.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 32),
            _OptionCard(
              icon: Icons.photo_camera_outlined,
              title: 'Capture Photo',
              subtitle: 'Use your camera to take a new photo',
              iconColor: colorScheme.primary,
              onTap: _isPicking ? null : () => _pickImage(ImageSource.camera),
            ),
            const SizedBox(height: 16),
            _OptionCard(
              icon: Icons.photo_library_outlined,
              title: 'Upload Photo',
              subtitle: 'Choose an existing photo from your gallery',
              iconColor: colorScheme.secondary,
              onTap:
                  _isPicking ? null : () => _pickImage(ImageSource.gallery),
            ),
            if (_isPicking) ...[
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
    );
  }

  /// Shown after a photo has been selected: full preview + actions.
  Widget _buildPreviewView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.file(
                File(_selectedImage!.path),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.image_outlined,
                          size: 64,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 8),
                        Text('Photo selected:\n${_selectedImage!.name}',
                            textAlign: TextAlign.center),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _confirmPhoto,
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Use This Photo'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed:
                _isPicking ? null : () => _pickImage(ImageSource.gallery),
            icon: const Icon(Icons.refresh),
            label: const Text('Choose Another Photo'),
          ),
        ],
      ),
    );
  }
}

/// A tappable card representing one of the two homepage options.
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