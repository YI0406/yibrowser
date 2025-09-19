import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';

/// Displays a local image with pinch-to-zoom support and an option to share.
class ImagePreviewPage extends StatelessWidget {
  const ImagePreviewPage({super.key, required this.filePath, this.title});

  final String filePath;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final displayName = title ?? path.basename(filePath);
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
              if (!File(filePath).existsSync()) return;
              await Share.shareXFiles([XFile(filePath)]);
            },
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 4,
          minScale: 0.5,
          child: Image.file(
            File(filePath),
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
