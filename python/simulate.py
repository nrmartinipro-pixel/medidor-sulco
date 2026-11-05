"""
simulate.py - Gera fotos sintéticas de pneu com laser de linha a partir de
profundidades conhecidas e confere se tread_depth.py as recupera.

Serve como teste de regressão do algoritmo: rode sempre que mexer nele.
    python simulate.py
"""

from __future__ import annotations

import math
import sys

import cv2
import numpy as np

from tread_depth import CameraModel, analisar, anotar

# Câmera típica de celular em 1440x1080 (focal ~1400 px), gabarito a 80 mm, laser a 35°
CAM = CameraModel(fy=1400.0, cy=540.0, z0_mm=80.0, theta_deg=35.0)
FX, CX = 1400.0, 720.0
W, H = 1440, 1080

# Sulcos: (centro em mm no plano do bloco, largura do fundo mm, profundidade mm)
SULCOS = [(-28.0, 7.0, 8.0), (-9.0, 6.0, 4.5), (9.0, 6.0, 2.4), (28.0, 6.0, 1.2)]
PAREDE_MM = 1.0  # largura da rampa da parede (rebarba do molde)


def perfil_real(x_mm: float) -> float:
    """Profundidade real d(x) da banda, com paredes levemente inclinadas."""
    for c, larg, prof in SULCOS:
        r = abs(x_mm - c)
        if r <= larg / 2:
            return prof
        if r <= larg / 2 + PAREDE_MM:
            return prof * (1 - (r - larg / 2) / PAREDE_MM)
    return 0.0


def gerar(seed: int = 0, inclinacao: float = 0.015, ruido: float = 6.0,
          jpeg: int | None = 85) -> np.ndarray:
    rng = np.random.default_rng(seed)

    # Borracha: cinza escuro com textura
    base = rng.normal(42, 10, (H, W)).astype(np.float32)
    base = cv2.GaussianBlur(base, (0, 0), 2.0)
    img = np.dstack([base, base, base * 1.02])

    t = math.tan(math.radians(CAM.theta_deg))
    y_l0 = (470 - CAM.cy) * CAM.z0_mm / CAM.fy  # altura da linha no bloco (mm)

    linhas = np.arange(H, dtype=np.float32)
    for u in range(W):
        x_mm = (u - CX) * CAM.z0_mm / FX
        d = perfil_real(x_mm)
        # sulco mais escuro (sombra)
        if d > 0.3:
            img[:, u, :] *= 0.75
        y_l = y_l0 + inclinacao * x_mm                    # celular levemente torto
        v = CAM.cy + CAM.fy * (y_l + d * t) / (CAM.z0_mm + d)
        perfil = np.exp(-0.5 * ((linhas - v) / 2.2) ** 2)
        intens = 1.0 - 0.25 * (d / 8.0)                   # laser mais fraco no fundo
        img[:, u, 2] += 255 * 1.4 * intens * perfil        # R satura no núcleo
        img[:, u, 1] += 255 * 0.35 * intens * perfil ** 3  # núcleo puxa para branco
        img[:, u, 0] += 255 * 0.30 * intens * perfil ** 3

    img += rng.normal(0, ruido, img.shape).astype(np.float32)
    img = np.clip(img, 0, 255).astype(np.uint8)
    if jpeg:
        ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, jpeg])
        img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    return img


def main() -> int:
    esperado = [p for _, _, p in SULCOS]
    piores = []
    for seed in range(5):
        img = gerar(seed=seed, inclinacao=0.01 * (seed - 2))
        res = analisar(img, CAM)
        medidos = [s["profundidade_mm"] for s in res["sulcos"]]
        if len(medidos) != len(esperado):
            print(f"seed {seed}: esperava {len(esperado)} sulcos, achei {medidos}")
            return 1
        erros = [m - e for m, e in zip(medidos, esperado)]
        piores.append(max(abs(e) for e in erros))
        status = [s["status"] for s in res["sulcos"]]
        print(f"seed {seed}: medido {medidos}  erro máx {piores[-1]:.2f} mm  {status}")
        if seed == 0:
            cv2.imwrite("sintetica.jpg", img)
            cv2.imwrite("sintetica_anotada.png", anotar(img, res))

    print(f"\nreal: {esperado}\npior erro em 5 imagens: {max(piores):.2f} mm")
    return 0 if max(piores) < 0.2 else 1


if __name__ == "__main__":
    sys.exit(main())
