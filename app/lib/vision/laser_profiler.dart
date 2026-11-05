import 'dart:math' as math;
import 'dart:typed_data';

import '../core/calibration.dart';

/// Port em Dart puro do algoritmo de python/tread_depth.py (Abordagem A).
/// Roda num isolate (compute) sobre um quadro copiado do stream da câmera.
/// Sem dependência nativa: funciona igual em Android (YUV420) e iOS (BGRA).

enum PixelLayout { yuv420, bgra8888 }

/// Cópia mínima de um CameraImage, segura para enviar a outro isolate.
class FrameData {
  final PixelLayout layout;
  final int width, height;
  final Uint8List p0; // Y (yuv) ou BGRA
  final int p0RowStride;
  final Uint8List? pV; // plano Cr (só yuv)
  final int vRowStride, vPixelStride;

  const FrameData({
    required this.layout,
    required this.width,
    required this.height,
    required this.p0,
    required this.p0RowStride,
    this.pV,
    this.vRowStride = 0,
    this.vPixelStride = 1,
  });

  /// "Vermelhidão" 0..~255 do pixel. Laser 650 nm = Cr alto (yuv) ou R >> G,B.
  /// O núcleo saturado (quase branco) sai com peso 0; como ele é simétrico
  /// dentro da linha, o centróide continua correto.
  int redness(int u, int v) {
    if (layout == PixelLayout.yuv420) {
      final y = p0[v * p0RowStride + u];
      final cr = pV![(v >> 1) * vRowStride + (u >> 1) * vPixelStride];
      if (cr < 145 || y < 50) return 0;
      return math.min(255, math.max(0, (cr - 128) * 3 + (y >> 2)));
    } else {
      final i = v * p0RowStride + u * 4;
      final b = p0[i], g = p0[i + 1], r = p0[i + 2];
      final d = r - math.max(g, b);
      return (r > 110 && d > 35) ? r : 0;
    }
  }
}

class Groove {
  final int uStart, uEnd;
  final double depthMm, spreadMm;
  const Groove(this.uStart, this.uEnd, this.depthMm, this.spreadMm);
}

class MeasurementResult {
  final List<Groove> grooves;
  final double coverage; // fração de colunas onde a linha foi achada
  final String? error;
  const MeasurementResult(this.grooves, this.coverage, [this.error]);

  double? get minDepth =>
      grooves.isEmpty ? null : grooves.map((g) => g.depthMm).reduce(math.min);
}

class MeasureRequest {
  final FrameData frame;
  final CameraModel cam;
  final double roiTop, roiBottom; // faixa vertical analisada (0..1)
  const MeasureRequest(this.frame, this.cam, {this.roiTop = 0.2, this.roiBottom = 0.8});
}

const _step = 2;        // analisa 1 coluna a cada 2 (metade do custo)
const _janela = 7;      // ±px em torno do pico para o centróide
const _tolRef = 1.5;    // px, tolerância do ajuste da superfície
const _minProf = 0.5;   // mm
const _minLargPx = 15;  // px
const _corteBorda = 0.25;

/// Ponto de entrada para `compute(medirQuadro, req)`.
MeasurementResult medirQuadro(MeasureRequest req) {
  final f = req.frame;
  final v0 = (f.height * req.roiTop).round();
  final v1 = (f.height * req.roiBottom).round();
  final u0 = (f.width * 0.04).round();
  final u1 = (f.width * 0.96).round();

  // 1+2) perfil subpixel v(u)
  final us = <double>[];
  final perfil = <double>[]; // NaN = sem linha
  for (var u = u0; u < u1; u += _step) {
    var pico = -1, picoV = 0;
    for (var v = v0; v < v1; v++) {
      final r = f.redness(u, v);
      if (r > picoV) {
        picoV = r;
        pico = v;
      }
    }
    us.add(u.toDouble());
    if (pico < 0) {
      perfil.add(double.nan);
      continue;
    }
    double s = 0, sv = 0;
    var n = 0;
    final a = math.max(v0, pico - _janela), b = math.min(v1, pico + _janela + 1);
    for (var v = a; v < b; v++) {
      final r = f.redness(u, v);
      if (r > 0) {
        s += r;
        sv += r * v;
        n++;
      }
    }
    perfil.add(n >= 2 ? sv / s : double.nan);
  }

  final validos = perfil.where((p) => !p.isNaN).length;
  final cobertura = perfil.isEmpty ? 0.0 : validos / perfil.length;
  if (validos < 20) {
    return MeasurementResult(const [], cobertura, 'Linha laser não encontrada');
  }

  // 3) referência robusta (reta) sobre os blocos
  var sel = List<bool>.generate(perfil.length, (i) => !perfil[i].isNaN);
  var (m, c) = _fitLinha(us, perfil, sel);
  for (var it = 0; it < 8; it++) {
    final novo = List<bool>.generate(
        perfil.length, (i) => !perfil[i].isNaN && (perfil[i] - (m * us[i] + c)) < _tolRef);
    if (novo.where((x) => x).length < 20) break;
    sel = novo;
    (m, c) = _fitLinha(us, perfil, sel);
  }

  // 4) triangulação exata (pinhole)
  final cam = req.cam;
  final t = math.tan(cam.thetaDeg * math.pi / 180);
  final d = List<double>.generate(perfil.length, (i) {
    if (perfil[i].isNaN) return double.nan;
    final a = (m * us[i] + c) - cam.cy;
    final b = perfil[i] - cam.cy;
    return cam.k * cam.z0Mm * (b - a) / (cam.fy * t - b);
  });

  // 5) sulcos = trechos contíguos com d > minProf (lacunas curtas toleradas)
  final minLarg = (_minLargPx / _step).ceil();
  final grooves = <Groove>[];
  var i = 0;
  while (i < d.length) {
    if (d[i].isNaN || d[i] <= _minProf) {
      i++;
      continue;
    }
    final ini = i;
    var lacuna = 0;
    while (i < d.length) {
      if (d[i].isNaN) {
        if (++lacuna > 3) break;
      } else if (d[i] > _minProf) {
        lacuna = 0;
      } else {
        break;
      }
      i++;
    }
    final fim = i - lacuna;
    final larg = fim - ini;
    if (larg < minLarg) continue;
    final corte = (larg * _corteBorda).floor();
    final centro = d.sublist(ini + corte, fim - corte).where((x) => !x.isNaN).toList()..sort();
    if (centro.length < 5) continue;
    final med = _quantil(centro, 0.5);
    final iqr = _quantil(centro, 0.75) - _quantil(centro, 0.25);
    grooves.add(Groove(us[ini].round(), us[fim - 1].round(), med, iqr));
  }
  return MeasurementResult(grooves, cobertura);
}

(double, double) _fitLinha(List<double> x, List<double> y, List<bool> sel) {
  double n = 0, sx = 0, sy = 0, sxx = 0, sxy = 0;
  for (var i = 0; i < x.length; i++) {
    if (!sel[i]) continue;
    n++;
    sx += x[i];
    sy += y[i];
    sxx += x[i] * x[i];
    sxy += x[i] * y[i];
  }
  final den = n * sxx - sx * sx;
  if (den.abs() < 1e-9) return (0, sy / n);
  final m = (n * sxy - sx * sy) / den;
  return (m, (sy - m * sx) / n);
}

double _quantil(List<double> ordenado, double q) {
  final pos = (ordenado.length - 1) * q;
  final lo = pos.floor(), hi = pos.ceil();
  return ordenado[lo] + (ordenado[hi] - ordenado[lo]) * (pos - lo);
}

/// Mediana móvel das últimas N leituras válidas: tira a tremedeira da mão.
class FiltroTemporal {
  final int n;
  final _buf = <double>[];
  FiltroTemporal([this.n = 7]);

  double? add(double? v) {
    if (v == null) return null;
    _buf.add(v);
    if (_buf.length > n) _buf.removeAt(0);
    if (_buf.length < 3) return null;
    final s = [..._buf]..sort();
    return s[s.length ~/ 2];
  }

  /// Leitura estável = as últimas N ficaram dentro de ±0,3 mm.
  bool get estavel {
    if (_buf.length < n) return false;
    final mn = _buf.reduce(math.min), mx = _buf.reduce(math.max);
    return (mx - mn) <= 0.6;
  }

  void reset() => _buf.clear();
}
