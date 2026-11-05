import 'package:flutter/material.dart';

/// Faixas de segurança (TWI brasileiro = 1,6 mm).
///   Verde    > 3,0 mm
///   Amarelo  > 1,6 mm e <= 3,0 mm
///   Vermelho <= 1,6 mm  (pneu careca)
enum SafetyStatus { verde, amarelo, vermelho }

const double kTwiMm = 1.6;
const double kAtencaoMm = 3.0;

SafetyStatus classificar(double profundidadeMm) {
  if (profundidadeMm <= kTwiMm) return SafetyStatus.vermelho;
  if (profundidadeMm <= kAtencaoMm) return SafetyStatus.amarelo;
  return SafetyStatus.verde;
}

extension SafetyStatusUi on SafetyStatus {
  Color get cor => switch (this) {
        SafetyStatus.verde => const Color(0xFF2E9E44),
        SafetyStatus.amarelo => const Color(0xFFF2B705),
        SafetyStatus.vermelho => const Color(0xFFD62828),
      };

  String get rotulo => switch (this) {
        SafetyStatus.verde => 'Seguro',
        SafetyStatus.amarelo => 'Atenção: planeje a troca',
        SafetyStatus.vermelho => 'Pneu careca (abaixo do TWI)',
      };
}
