// ============================================================
// SP Smart Mobile — Camera Preview Widget (Fase 4)
// ============================================================
// Conecta-se ao TextureRegistry nativo do Android para exibir
// a saída do Camera2 sem overhead de cópia (zero-copy).
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

@immutable
class CameraPreviewTransform {
  const CameraPreviewTransform({
    this.rotationDegrees = 0,
    this.frontFacing = false,
  });

  final int rotationDegrees;
  final bool frontFacing;
}

final cameraPreviewTransformNotifier = ValueNotifier(
  const CameraPreviewTransform(),
);

void updateCameraPreviewTransform(Map<dynamic, dynamic>? info) {
  if (info == null) return;
  cameraPreviewTransformNotifier.value = CameraPreviewTransform(
    rotationDegrees: (info['rotationDegrees'] as num?)?.toInt() ?? 0,
    frontFacing: info['frontFacing'] == true,
  );
}

class CameraPreviewWidget extends StatefulWidget {
  const CameraPreviewWidget({super.key});

  @override
  State<CameraPreviewWidget> createState() => _CameraPreviewWidgetState();
}

class _CameraPreviewWidgetState extends State<CameraPreviewWidget>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('sp.smart/srt');
  int _textureId = -1;
  bool _isLoading = true;
  bool _isInitializing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializePreview();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _textureId < 0) {
      _initializePreview();
    }
  }

  Future<void> _initializePreview() async {
    if (_isInitializing || _textureId >= 0) return;
    _isInitializing = true;

    try {
      final cameraStatus = await Permission.camera.request();
      // O microfone é necessário para o IFB, mas sua recusa não deve impedir
      // que o operador veja a câmera local.
      await Permission.microphone.request();

      if (!cameraStatus.isGranted) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = cameraStatus.isPermanentlyDenied
                ? 'Permissão da câmera bloqueada nas configurações'
                : 'Permissão da câmera negada';
          });
        }
        return;
      }

      final id = await _channel.invokeMethod<int>('startPreview', {
        'width': 1920,
        'height': 1080,
        'fps': 30,
        'bitrateKbps': 2000,
      });
      final info = await _channel.invokeMapMethod<dynamic, dynamic>(
        'getCameraInfo',
      );
      updateCameraPreviewTransform(info);
      if (mounted && id != null) {
        setState(() {
          _textureId = id;
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } on PlatformException catch (e) {
      debugPrint('[CameraPreviewWidget] Error starting preview: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Falha ao iniciar a câmera';
        });
      }
    } finally {
      _isInitializing = false;
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, size: 48, color: Colors.white24),
            const SizedBox(height: 8),
            Text(
              _errorMessage ?? 'Câmera não iniciada',
              style: const TextStyle(color: Colors.white38),
            ),
          ],
        ),
      );
    }

    // Preview 16:9 preenchendo a operação em paisagem, com crop central.
    return ValueListenableBuilder<CameraPreviewTransform>(
      valueListenable: cameraPreviewTransformNotifier,
      builder: (context, transform, _) {
        Widget texture = SizedBox(
          width: 1920,
          height: 1080,
          child: Texture(textureId: _textureId),
        );
        if (transform.frontFacing) {
          texture = Transform.flip(
            flipX: true,
            child: texture,
          );
        }
        return ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: RotatedBox(
              quarterTurns: (transform.rotationDegrees ~/ 90) % 4,
              child: texture,
            ),
          ),
        );
      },
    );
  }
}
