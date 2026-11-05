import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Abordagem B: a view nativa (ARCore / ARKit) desenha a câmera; o Flutter
/// desenha a interface por cima e repassa o toque pelo MethodChannel.
///
/// Contrato do canal 'medidor/depth':
///   isSupported            -> bool
///   measureAt {x, y}       -> {depthMm, spreadMm, distanceMm, frames}
///                             x, y normalizados (0..1) na área da view
///   erros: PlatformException(code: 'TOO_FAR' | 'LOW_CONFIDENCE' | 'NO_DEPTH')
class NativeDepth {
  static const _ch = MethodChannel('medidor/depth');
  static const viewType = 'medidor/ar-depth';

  static Future<bool> isSupported() async {
    try {
      return await _ch.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<DepthReading> measureAt(Offset normalized) async {
    final r = await _ch.invokeMapMethod<String, dynamic>(
      'measureAt',
      {'x': normalized.dx, 'y': normalized.dy},
    );
    return DepthReading(
      depthMm: (r!['depthMm'] as num).toDouble(),
      spreadMm: (r['spreadMm'] as num).toDouble(),
      distanceMm: (r['distanceMm'] as num).toDouble(),
      frames: r['frames'] as int,
    );
  }
}

class DepthReading {
  final double depthMm, spreadMm, distanceMm;
  final int frames;
  const DepthReading({
    required this.depthMm,
    required this.spreadMm,
    required this.distanceMm,
    required this.frames,
  });

  /// Com ToF/LiDAR de celular a dispersão costuma ser de vários mm.
  /// Acima de 1 mm não dá para afirmar o status do TWI com segurança.
  bool get confiavel => spreadMm <= 1.0;
}

class NativeDepthView extends StatelessWidget {
  final ValueChanged<Offset> onTapNormalized;
  const NativeDepthView({super.key, required this.onTapNormalized});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final view = switch (defaultTargetPlatform) {
        TargetPlatform.android => PlatformViewLink(
            viewType: NativeDepth.viewType,
            surfaceFactory: (context, controller) => AndroidViewSurface(
              controller: controller as AndroidViewController,
              gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
              hitTestBehavior: PlatformViewHitTestBehavior.transparent,
            ),
            onCreatePlatformView: (params) =>
                // Hybrid composition: necessário para GLSurfaceView do ARCore
                PlatformViewsService.initExpensiveAndroidView(
                  id: params.id,
                  viewType: NativeDepth.viewType,
                  layoutDirection: TextDirection.ltr,
                  creationParamsCodec: const StandardMessageCodec(),
                )
                  ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
                  ..create(),
          ),
        TargetPlatform.iOS => const UiKitView(viewType: NativeDepth.viewType),
        _ => const Center(child: Text('Plataforma não suportada')),
      };
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => onTapNormalized(Offset(
          d.localPosition.dx / box.maxWidth,
          d.localPosition.dy / box.maxHeight,
        )),
        child: view,
      );
    });
  }
}
