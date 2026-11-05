import 'package:shared_preferences/shared_preferences.dart';

/// Parâmetros da triangulação (mesmos de python/tread_depth.py).
///
/// IMPORTANTE: fy e cy são em pixels DA RESOLUÇÃO DO STREAM analisado,
/// não da foto em resolução máxima. Se calibrou a câmera em 4000x3000 e o
/// stream é 1280x720, multiplique fy por 720/3000 (com o mesmo corte de FOV).
class CameraModel {
  final double fy;
  final double cy;
  final double z0Mm;
  final double thetaDeg;
  final double k;

  const CameraModel({
    required this.fy,
    required this.cy,
    required this.z0Mm,
    required this.thetaDeg,
    this.k = 1.0,
  });

  /// Valores de partida para um gabarito a 80 mm com laser a 35°,
  /// stream 1280x720. Substitua pelos da sua calibração.
  static const padrao = CameraModel(fy: 950, cy: 360, z0Mm: 80, thetaDeg: 35);

  CameraModel copyWith({double? fy, double? cy, double? z0Mm, double? thetaDeg, double? k}) =>
      CameraModel(
        fy: fy ?? this.fy,
        cy: cy ?? this.cy,
        z0Mm: z0Mm ?? this.z0Mm,
        thetaDeg: thetaDeg ?? this.thetaDeg,
        k: k ?? this.k,
      );

  static Future<CameraModel> carregar() async {
    final p = await SharedPreferences.getInstance();
    return CameraModel(
      fy: p.getDouble('fy') ?? padrao.fy,
      cy: p.getDouble('cy') ?? padrao.cy,
      z0Mm: p.getDouble('z0') ?? padrao.z0Mm,
      thetaDeg: p.getDouble('theta') ?? padrao.thetaDeg,
      k: p.getDouble('k') ?? 1.0,
    );
  }

  Future<void> salvar() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('fy', fy);
    await p.setDouble('cy', cy);
    await p.setDouble('z0', z0Mm);
    await p.setDouble('theta', thetaDeg);
    await p.setDouble('k', k);
  }
}

/// Fator único que corrige erros de theta, Z0 e fy (todos quase multiplicativos).
/// Meça um bloco-padrão com degraus conhecidos (ex.: 2, 5 e 8 mm).
double calibrarK(List<double> medidos, List<double> reais) {
  double num = 0, den = 0;
  for (var i = 0; i < medidos.length; i++) {
    num += medidos[i] * reais[i];
    den += medidos[i] * medidos[i];
  }
  return den == 0 ? 1.0 : num / den;
}
