// ============================================================
// SP Smart Mobile — Camera Preview Widget (Fase 4)
// ============================================================
// Conecta-se ao TextureRegistry nativo do Android para exibir
// a saída do Camera2 sem overhead de cópia (zero-copy).
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CameraPreviewWidget extends StatefulWidget {
  const CameraPreviewWidget({super.key});

  @override
  State<CameraPreviewWidget> createState() => _CameraPreviewWidgetState();
}

class _CameraPreviewWidgetState extends State<CameraPreviewWidget> {
  static const _channel = MethodChannel('sp.smart/srt');
  int _textureId = -1;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchTextureId();
  }

  Future<void> _fetchTextureId() async {
    try {
      // O SrtEnginePlugin.kt (Android) expõe getTextureId()
      final id = await _channel.invokeMethod<int>('getTextureId');
      if (mounted && id != null) {
        setState(() {
          _textureId = id;
          _isLoading = false;
        });
      }
    } on PlatformException catch (e) {
      debugPrint('[CameraPreviewWidget] Error fetching texture: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00BCD4)),
      );
    }

    if (_textureId < 0) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off, size: 48, color: Colors.white24),
            SizedBox(height: 8),
            Text(
              'Câmera não iniciada',
              style: TextStyle(color: Colors.white38),
            ),
          ],
        ),
      );
    }

    // Aspect ratio 16:9 padrão do broadcast
    return AspectRatio(
      aspectRatio: 9.0 / 16.0, // Retrato (Mobile)
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Texture(textureId: _textureId),
      ),
    );
  }
}
