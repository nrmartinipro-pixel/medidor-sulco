"""
tread_depth.py - Medição de profundidade de sulco por triangulação a laser de linha.

Abordagem A do MVP. Este é o algoritmo de referência: o app (Dart/Kotlin/Swift)
replica exatamente estes passos. Mantenha os dois em sincronia.

Geometria (convenções):
  - Câmera olhando perpendicular à banda de rodagem, a Z0 mm da superfície dos blocos.
  - A linha laser cruza os sulcos (perpendicular a eles) e aparece ~horizontal na imagem.
  - O plano do laser é inclinado de um ângulo theta em relação ao eixo óptico,
    girando em torno da direção da própria linha. Um ponto mais fundo (sulco)
    desloca a linha no eixo v (linhas da imagem).

Modelo pinhole exato (v medido a partir do ponto principal cy, em pixels):
    a = v_topo  - cy        (linha sobre o bloco, Z = Z0)
    b = v_fundo - cy        (linha no fundo do sulco, Z = Z0 + d)
    d = Z0 * (b - a) / (fy * tan(theta) - b)

Aproximação de primeira ordem (útil para intuição e checagem):
    d ≈ (b - a) * (Z0 / fy) / tan(theta)  =  deslocamento_px * escala_mm_por_px / tan(theta)

Uso:
    python tread_depth.py foto.jpg --fy 1400 --cy 540 --z0 80 --theta 35
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, asdict

import cv2
import numpy as np


# --------------------------------------------------------------------------- #
# Parâmetros
# --------------------------------------------------------------------------- #
@dataclass
class CameraModel:
    fy: float          # distância focal em pixels (eixo vertical da imagem)
    cy: float          # linha do ponto principal (≈ altura/2 sem calibração)
    z0_mm: float       # distância câmera -> topo dos blocos (fixada pelo gabarito)
    theta_deg: float   # ângulo do plano laser em relação ao eixo óptico
    k: float = 1.0     # fator de correção obtido no bloco-padrão (ver calibrar_k)


def calibrar_k(medidos_mm: list[float], reais_mm: list[float]) -> float:
    """Erros de theta, Z0 e fy são quase puramente multiplicativos (~4 %/grau),
    então um único fator, ajustado por mínimos quadrados num bloco-padrão com
    degraus conhecidos (ex.: 2, 5 e 8 mm), corrige todos eles juntos."""
    m, r = np.asarray(medidos_mm, float), np.asarray(reais_mm, float)
    return float((m * r).sum() / (m * m).sum())


TWI_MM = 1.6           # limite legal (Resolução CONTRAN 558/80)
ATENCAO_MM = 3.0


def classificar(prof_mm: float) -> str:
    if prof_mm <= TWI_MM:
        return "VERMELHO"
    if prof_mm <= ATENCAO_MM:
        return "AMARELO"
    return "VERDE"


# --------------------------------------------------------------------------- #
# 1) Segmentação da linha laser
# --------------------------------------------------------------------------- #
def mascara_laser(bgr: np.ndarray) -> np.ndarray:
    """Máscara do laser vermelho em HSV.

    O vermelho fica nas duas pontas do círculo de matiz (0-10 e 170-180).
    O núcleo do laser costuma saturar e virar quase branco; ele é aceito
    quando está colado em pixels vermelhos (dilatação), o que evita pegar
    reflexos brancos soltos na borracha.
    """
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    r1 = cv2.inRange(hsv, (0, 70, 110), (12, 255, 255))
    r2 = cv2.inRange(hsv, (165, 70, 110), (180, 255, 255))
    vermelho = cv2.bitwise_or(r1, r2)

    nucleo = cv2.inRange(hsv, (0, 0, 230), (180, 90, 255))
    vizinho = cv2.dilate(vermelho, np.ones((7, 7), np.uint8))
    nucleo = cv2.bitwise_and(nucleo, vizinho)

    m = cv2.bitwise_or(vermelho, nucleo)
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    return m


# --------------------------------------------------------------------------- #
# 2) Perfil subpixel: para cada coluna, o centro da linha laser
# --------------------------------------------------------------------------- #
def extrair_perfil(bgr: np.ndarray, mask: np.ndarray, janela: int = 7) -> np.ndarray:
    """Retorna v(u): linha (float) do centro do laser em cada coluna u, NaN se ausente.

    Peso = canal R dentro da máscara. Pega o pico da coluna e calcula o
    centróide ponderado numa janela de ±janela px (resolução ~0,1 px).
    """
    peso = bgr[:, :, 2].astype(np.float32) * (mask > 0)
    h, w = peso.shape
    perfil = np.full(w, np.nan, dtype=np.float64)
    linhas = np.arange(h, dtype=np.float64)

    for u in range(w):
        col = peso[:, u]
        pico = int(np.argmax(col))
        if col[pico] <= 0:
            continue
        a, b = max(0, pico - janela), min(h, pico + janela + 1)
        seg = col[a:b]
        s = seg.sum()
        if s > 0 and np.count_nonzero(seg) >= 2:
            perfil[u] = float((seg * linhas[a:b]).sum() / s)
    return perfil


# --------------------------------------------------------------------------- #
# 3) Referência: ajuste robusto da superfície dos blocos
# --------------------------------------------------------------------------- #
def ajustar_referencia(perfil: np.ndarray, grau: int = 1, tol_px: float = 1.5,
                       iteracoes: int = 8) -> np.ndarray:
    """Ajusta um polinômio só aos pontos dos blocos (nível de referência).

    Os sulcos só desviam a linha para um lado (+v), então o ajuste é refeito
    descartando pontos acima da tolerância. Grau 1 corrige inclinação do
    celular; grau 2 corrige a curvatura transversal da banda.
    Retorna os coeficientes (np.polyfit).
    """
    u = np.arange(perfil.size, dtype=np.float64)
    ok = ~np.isnan(perfil)
    if ok.sum() < 20:
        raise ValueError("linha laser não encontrada na imagem")
    sel = ok.copy()
    coef = np.polyfit(u[sel], perfil[sel], grau)
    for _ in range(iteracoes):
        res = perfil - np.polyval(coef, u)
        novo = ok & (res < tol_px)
        if novo.sum() < 20 or np.array_equal(novo, sel):
            break
        sel = novo
        coef = np.polyfit(u[sel], perfil[sel], grau)
    return coef


# --------------------------------------------------------------------------- #
# 4) Conversão px -> mm (triangulação)
# --------------------------------------------------------------------------- #
def profundidade_mm(v_topo: np.ndarray, v_fundo: np.ndarray, cam: CameraModel) -> np.ndarray:
    a = v_topo - cam.cy
    b = v_fundo - cam.cy
    t = math.tan(math.radians(cam.theta_deg))
    return cam.k * cam.z0_mm * (b - a) / (cam.fy * t - b)


# --------------------------------------------------------------------------- #
# 5) Segmentação dos sulcos e medida de cada um
# --------------------------------------------------------------------------- #
def medir_sulcos(d: np.ndarray, min_prof: float = 0.5, min_larg_px: int = 15,
                 corte_borda: float = 0.25, max_lacuna: int = 6) -> list[dict]:
    """Agrupa colunas contíguas com d > min_prof e mede o fundo de cada sulco.

    - Lacunas curtas (NaN) dentro do sulco são toleradas (parede, sujeira).
    - As bordas de cada sulco (transição/parede) são descartadas: usa-se só
      a parte central (corte_borda de cada lado) e a mediana dela.
    """
    w = d.size
    dentro = np.where(np.isnan(d), False, d > min_prof)

    # fecha lacunas curtas de NaN entre trechos de sulco
    nan_idx = np.isnan(d)
    i = 0
    while i < w:
        if nan_idx[i]:
            j = i
            while j < w and nan_idx[j]:
                j += 1
            if 0 < i and j < w and (j - i) <= max_lacuna and dentro[i - 1] and dentro[j]:
                dentro[i:j] = True
            i = j
        else:
            i += 1

    sulcos = []
    u = 0
    while u < w:
        if not dentro[u]:
            u += 1
            continue
        ini = u
        while u < w and dentro[u]:
            u += 1
        fim = u  # exclusivo
        larg = fim - ini
        if larg < min_larg_px:
            continue
        c = int(larg * corte_borda)
        centro = d[ini + c: fim - c]
        centro = centro[~np.isnan(centro)]
        if centro.size < 5:
            continue
        prof = float(np.median(centro))
        sulcos.append({
            "u_inicio": ini,
            "u_fim": fim - 1,
            "largura_px": larg,
            "profundidade_mm": round(prof, 2),
            "dispersao_mm": round(float(np.percentile(centro, 75) - np.percentile(centro, 25)), 2),
            "status": classificar(prof),
        })
    return sulcos


# --------------------------------------------------------------------------- #
# Pipeline completo
# --------------------------------------------------------------------------- #
def analisar(bgr: np.ndarray, cam: CameraModel, grau_ref: int = 1) -> dict:
    mask = mascara_laser(bgr)
    perfil = extrair_perfil(bgr, mask)
    coef = ajustar_referencia(perfil, grau=grau_ref)
    u = np.arange(perfil.size, dtype=np.float64)
    v_ref = np.polyval(coef, u)
    d = profundidade_mm(v_ref, perfil, cam)
    sulcos = medir_sulcos(d)
    minimo = min((s["profundidade_mm"] for s in sulcos), default=None)
    return {
        "camera": asdict(cam),
        "cobertura_linha": round(float(np.mean(~np.isnan(perfil))), 3),
        "sulcos": sulcos,
        "menor_sulco_mm": minimo,
        "status_geral": classificar(minimo) if minimo is not None else "SEM_LEITURA",
        "_perfil": perfil,
        "_v_ref": v_ref,
    }


CORES = {"VERDE": (60, 180, 60), "AMARELO": (0, 200, 255), "VERMELHO": (40, 40, 230)}


def anotar(bgr: np.ndarray, res: dict) -> np.ndarray:
    out = bgr.copy()
    perfil, v_ref = res["_perfil"], res["_v_ref"]
    pts_ref = np.stack([np.arange(v_ref.size), v_ref], 1).astype(np.int32)
    cv2.polylines(out, [pts_ref], False, (255, 200, 0), 1)
    for u, v in enumerate(perfil):
        if not np.isnan(v):
            out[int(round(v)), u] = (0, 255, 0)
    for s in res["sulcos"]:
        cor = CORES[s["status"]]
        x0, x1 = s["u_inicio"], s["u_fim"]
        y = int(np.nanmax(perfil[x0:x1 + 1])) + 25
        cv2.rectangle(out, (x0, y - 18), (x1, y + 8), cor, 2)
        cv2.putText(out, f'{s["profundidade_mm"]:.1f} mm', (x0 + 3, y + 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, cor, 2, cv2.LINE_AA)
    txt = f'Menor sulco: {res["menor_sulco_mm"]} mm  [{res["status_geral"]}]'
    cv2.putText(out, txt, (20, 40), cv2.FONT_HERSHEY_SIMPLEX, 1.0,
                CORES.get(res["status_geral"], (255, 255, 255)), 2, cv2.LINE_AA)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Profundidade de sulco por laser de linha")
    ap.add_argument("imagem")
    ap.add_argument("--fy", type=float, required=True, help="focal em px")
    ap.add_argument("--cy", type=float, help="ponto principal (padrão: altura/2)")
    ap.add_argument("--z0", type=float, required=True, help="câmera->bloco em mm")
    ap.add_argument("--theta", type=float, required=True, help="ângulo do laser em graus")
    ap.add_argument("--k", type=float, default=1.0, help="fator de calibração do bloco-padrão")
    ap.add_argument("--grau", type=int, default=1, help="grau do ajuste da referência")
    ap.add_argument("--saida", default="anotada.png")
    a = ap.parse_args()

    img = cv2.imread(a.imagem)
    if img is None:
        raise SystemExit(f"não consegui abrir {a.imagem}")
    cam = CameraModel(a.fy, a.cy if a.cy is not None else img.shape[0] / 2, a.z0, a.theta, a.k)
    res = analisar(img, cam, a.grau)
    cv2.imwrite(a.saida, anotar(img, res))
    print(json.dumps({k: v for k, v in res.items() if not k.startswith("_")},
                     indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
