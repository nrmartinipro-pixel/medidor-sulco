import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/calibration.dart';
import '../core/safety.dart';
import '../depth/native_depth_view.dart';
import '../vision/laser_profiler.dart';

enum Modo { laser, depthNativo }

class MeasureScreen extends StatefulWidget {
  const MeasureScreen({super.key});
  @override
  State<MeasureScreen> createState() => _MeasureScreenState();
}

class _MeasureScreenState extends State<MeasureScreen> {
  static const _roiTop = 0.2, _roiBottom = 0.8;
  static const _intervalo = Duration(milliseconds: 180); // ~5 análises/s

  Modo _modo = Modo.laser;
  bool _depthSuportado = false;

  CameraController? _cam;
  CameraModel _calib = CameraModel.padrao;
  bool _ocupado = false;
  DateTime _ultimo = DateTime.fromMillisecondsSinceEpoch(0);

  final _filtro = FiltroTemporal(7);
  double? _profMm;
  MeasurementResult? _ultimoResultado;
  String? _aviso;
  bool _congelado = false;
  bool _medindoB = false;

  @override
  void initState() {
    super.initState();
    _iniciar();
  }

  Future<void> _iniciar() async {
    _calib = await CameraModel.carregar();
    _depthSuportado = await NativeDepth.isSupported();
    await _abrirCamera();
  }

  // ------------------------------------------------------------------ A ---
  Future<void> _abrirCamera() async {
    final cams = await availableCameras();
    final traseira = cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cams.first,
    );
    final ctrl = CameraController(
      traseira,
      ResolutionPreset.high, // 1280x720: fy da calibração deve ser nesta resolução
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.yuv420 : ImageFormatGroup.bgra8888,
    );
    await ctrl.initialize();
    // Laser fica muito mais nítido com a imagem subexposta e o foco travado.
    try {
      await ctrl.setExposureOffset(-1.5);
      await ctrl.setFocusMode(FocusMode.locked);
      await ctrl.setFlashMode(FlashMode.off);
    } catch (_) {/* nem todo aparelho aceita */}
    await ctrl.startImageStream(_onQuadro);
    if (!mounted) return;
    setState(() => _cam = ctrl);
  }

  Future<void> _fecharCamera() async {
    final c = _cam;
    _cam = null;
    if (c != null) {
      if (c.value.isStreamingImages) await c.stopImageStream();
      await c.dispose();
    }
  }

  void _onQuadro(CameraImage img) {
    final agora = DateTime.now();
    if (_ocupado || _congelado || agora.difference(_ultimo) < _intervalo) return;
    _ocupado = true;
    _ultimo = agora;

    final frame = _copiar(img);
    compute(medirQuadro, MeasureRequest(frame, _calib, roiTop: _roiTop, roiBottom: _roiBottom))
        .then((res) {
      if (!mounted) return;
      final suav = _filtro.add(res.minDepth);
      setState(() {
        _ultimoResultado = res;
        if (suav != null) _profMm = suav;
        _aviso = res.error ??
            (res.coverage < 0.6 ? 'Linha laser incompleta: alinhe ao guia' : null);
      });
    }).whenComplete(() => _ocupado = false);
  }

  FrameData _copiar(CameraImage img) {
    if (img.format.group == ImageFormatGroup.yuv420) {
      final y = img.planes[0], v = img.planes[2];
      return FrameData(
        layout: PixelLayout.yuv420,
        width: img.width,
        height: img.height,
        p0: Uint8List.fromList(y.bytes),
        p0RowStride: y.bytesPerRow,
        pV: Uint8List.fromList(v.bytes),
        vRowStride: v.bytesPerRow,
        vPixelStride: v.bytesPerPixel ?? 1,
      );
    }
    final p = img.planes[0];
    return FrameData(
      layout: PixelLayout.bgra8888,
      width: img.width,
      height: img.height,
      p0: Uint8List.fromList(p.bytes),
      p0RowStride: p.bytesPerRow,
    );
  }

  // ------------------------------------------------------------------ B ---
  Future<void> _tocarB(Offset pos) async {
    if (_medindoB) return;
    setState(() {
      _medindoB = true;
      _aviso = 'Medindo… mantenha o celular parado';
    });
    try {
      final r = await NativeDepth.measureAt(pos);
      setState(() {
        _profMm = r.depthMm;
        _aviso = r.confiavel
            ? 'Distância ${r.distanceMm.toStringAsFixed(0)} mm · ${r.frames} quadros'
            : 'Leitura instável (±${r.spreadMm.toStringAsFixed(1)} mm): confirme com o laser';
      });
    } on PlatformException catch (e) {
      setState(() => _aviso = switch (e.code) {
            'TOO_FAR' => 'Aproxime o celular do pneu',
            'LOW_CONFIDENCE' => 'Pouca confiança no sensor: melhore a luz',
            _ => e.message ?? 'Sem leitura de profundidade',
          });
    } finally {
      if (mounted) setState(() => _medindoB = false);
    }
  }

  Future<void> _trocarModo(Modo m) async {
    if (m == _modo) return;
    _filtro.reset();
    setState(() {
      _modo = m;
      _profMm = null;
      _aviso = null;
      _ultimoResultado = null;
    });
    // ARCore/ARKit precisam da câmera só para eles
    if (m == Modo.depthNativo) {
      await _fecharCamera();
    } else {
      await _abrirCamera();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _fecharCamera();
    super.dispose();
  }

  // ----------------------------------------------------------------- UI ---
  @override
  Widget build(BuildContext context) {
    final status = _profMm == null ? null : classificar(_profMm!);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Row(children: [
        Expanded(child: _areaCamera()),
        SizedBox(width: 300, child: _painel(status)),
      ]),
    );
  }

  Widget _areaCamera() {
    if (_modo == Modo.depthNativo) {
      return Stack(fit: StackFit.expand, children: [
        NativeDepthView(onTapNormalized: _tocarB),
        const IgnorePointer(child: Center(child: _Mira())),
      ]);
    }
    final c = _cam;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(fit: StackFit.expand, children: [
      FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: c.value.previewSize!.width,
          height: c.value.previewSize!.height,
          child: CameraPreview(c),
        ),
      ),
      IgnorePointer(
        child: CustomPaint(
          painter: _GuiaPainter(_roiTop, _roiBottom, _ultimoResultado,
              c.value.previewSize!.width),
        ),
      ),
    ]);
  }

  Widget _painel(SafetyStatus? status) {
    final cor = status?.cor ?? Colors.grey.shade700;
    final grooves = _ultimoResultado?.grooves ?? const <Groove>[];
    return Container(
      color: const Color(0xFF111418),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<Modo>(
          segments: [
            const ButtonSegment(value: Modo.laser, label: Text('Laser'), icon: Icon(Icons.linear_scale)),
            ButtonSegment(
              value: Modo.depthNativo,
              label: const Text('ToF/LiDAR'),
              icon: const Icon(Icons.sensors),
              enabled: _depthSuportado,
            ),
          ],
          selected: {_modo},
          onSelectionChanged: (s) => _trocarModo(s.first),
        ),
        const Spacer(),
        Text('Profundidade', style: TextStyle(color: Colors.grey.shade400, fontSize: 16)),
        Text(
          _profMm == null ? '— mm' : '${_profMm!.toStringAsFixed(1)} mm',
          style: const TextStyle(fontSize: 52, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        const SizedBox(height: 12),
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          decoration: BoxDecoration(color: cor, borderRadius: BorderRadius.circular(12)),
          child: Text(
            status?.rotulo ?? 'Aguardando leitura',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
          ),
        ),
        const SizedBox(height: 8),
        Text('Limite legal (TWI): 1,6 mm',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade500)),
        if (_modo == Modo.laser && grooves.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final g in grooves)
                Chip(
                  label: Text('${g.depthMm.toStringAsFixed(1)}'),
                  backgroundColor: classificar(g.depthMm).cor.withValues(alpha: 0.25),
                  side: BorderSide(color: classificar(g.depthMm).cor),
                ),
            ],
          ),
        ],
        const Spacer(),
        if (_aviso != null)
          Text(_aviso!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.amberAccent)),
        const SizedBox(height: 8),
        if (_modo == Modo.laser)
          FilledButton.icon(
            onPressed: () => setState(() => _congelado = !_congelado),
            icon: Icon(_congelado ? Icons.play_arrow : Icons.pause),
            label: Text(_congelado ? 'Retomar' : (_filtro.estavel ? 'Registrar (estável)' : 'Registrar')),
          )
        else
          Text(_medindoB ? 'Medindo…' : 'Toque no fundo do sulco',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade400)),
      ]),
    );
  }
}

/// Faixa-guia: o usuário encaixa a linha laser entre as duas réguas.
class _GuiaPainter extends CustomPainter {
  final double top, bottom, larguraImagem;
  final MeasurementResult? res;
  _GuiaPainter(this.top, this.bottom, this.res, this.larguraImagem);

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(0, s.height * top), Offset(s.width, s.height * top), p);
    canvas.drawLine(Offset(0, s.height * bottom), Offset(s.width, s.height * bottom), p);
    // marca cada sulco detectado com a cor do status
    final esc = s.width / larguraImagem;
    for (final g in res?.grooves ?? const <Groove>[]) {
      final cor = classificar(g.depthMm).cor;
      canvas.drawRect(
        Rect.fromLTRB(g.uStart * esc, s.height * bottom - 10, g.uEnd * esc, s.height * bottom),
        Paint()..color = cor,
      );
    }
  }

  @override
  bool shouldRepaint(_GuiaPainter old) => old.res != res;
}

class _Mira extends StatelessWidget {
  const _Mira();
  @override
  Widget build(BuildContext context) => Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white70, width: 2),
        ),
        child: const Center(child: Icon(Icons.add, color: Colors.white70)),
      );
}
