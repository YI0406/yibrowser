import 'dart:io';
import 'iap.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'app_localizations.dart';

/// Displays a local image with pinch-to-zoom support and an option to share.
class ImagePreviewPage extends StatefulWidget {
  const ImagePreviewPage({super.key, required this.filePath, this.title});

  final String filePath;
  final String? title;
  @override
  State<ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends State<ImagePreviewPage>
    with LanguageAwareState<ImagePreviewPage> {
  @override
  Widget build(BuildContext context) {
    final displayName = widget.title ?? path.basename(widget.filePath);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () async {
              final ok = await PurchaseService().ensurePremium(
                context: context,
                featureName: context.l10n('feature.export'),
              );
              if (!ok) return;
              if (!File(widget.filePath).existsSync()) return;
              await Share.shareXFiles([XFile(widget.filePath)]);
            },
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 4,
          minScale: 0.5,
          child: Image.file(
            File(widget.filePath),
            fit: BoxFit.contain,
            errorBuilder:
                (_, __, ___) => const Icon(
                  Icons.broken_image,
                  color: Colors.white54,
                  size: 64,
                ),
          ),
        ),
      ),
    );
  }
}
