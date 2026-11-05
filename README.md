# Medidor de Sulco — MVP (Flutter + Visão Computacional + Depth API)

App de celular que mede a profundidade dos sulcos da banda de rodagem em
milímetros e classifica pelo TWI brasileiro:

| Cor | Faixa | Significado |
|---|---|---|
| Verde | > 3,0 mm | Seguro |
| Amarelo | > 1,6 e ≤ 3,0 mm | Atenção, planejar troca |
| Vermelho | ≤ 1,6 mm | Abaixo do TWI (pneu careca) |

Duas abordagens convivem no mesmo app:

- **A — Laser de linha + câmera.** Funciona em qualquer smartphone e é a
  abordagem principal: chega a décimos de milímetro com gabarito e calibração.
- **B — ToF/LiDAR nativo** (ARCore Raw Depth / ARKit sceneDepth). Não precisa
  de acessório, mas tem precisão limitada (ver §5). Serve como triagem e não
  como base do laudo.

---

## 1. Arquitetura

```
┌──────────────────────────── Flutter (Dart) ────────────────────────────┐
│  MeasureScreen  ── UI: preview, faixa-guia, "Profundidade: 5.4 mm",    │
│       │             semáforo TWI, chips por sulco, Registrar            │
│       │                                                                 │
│       ├─ Modo A ─ camera (image stream) ─► compute(isolate)            │
│       │             FrameData (cópia YUV/BGRA)   laser_profiler.dart   │
│       │                                          └ HSV/Cr → perfil →   │
│       │                                            referência → mm     │
│       │                                                                 │
│       └─ Modo B ─ PlatformView 'medidor/ar-depth' + MethodChannel      │
│                    'medidor/depth' (isSupported, measureAt{x,y})       │
└───────────────────────────────┬─────────────────────────────────────────┘
              Android (Kotlin)  │  iOS (Swift)
     ArDepthView + ARCore Session  ARDepthView + ARSCNView/ARSession
     DepthMeasurer.kt              DepthMeasurer.swift
     (raw depth 16 bit + confiança)(smoothedSceneDepth + confidenceMap)
```

Por que essa divisão:

- **Modo A em Dart puro.** Não há dependência nativa: o mesmo código roda em
  Android (YUV420, usa o plano Cr) e iOS (BGRA). O processamento fica num
  isolate, a ~5 análises por segundo, para não travar o preview.
- **Modo B nativo.** ARCore e ARKit só existem nativamente e exigem a câmera
  exclusiva. Por isso o app fecha o `CameraController` ao trocar de modo. A
  view nativa desenha a câmera, e o Flutter desenha a interface por cima e
  repassa o toque.
- **App travado em paisagem.** Assim a linha laser horizontal na tela também
  é horizontal no buffer do sensor, sem rotação de quadros.

### Estrutura de pastas

```
python/
  tread_depth.py      algoritmo de referência (OpenCV) + CLI
  simulate.py         gerador de fotos sintéticas + teste de regressão
  sintetica*.{jpg,png} exemplo de entrada e saída anotada
app/
  pubspec.yaml
  lib/main.dart
  lib/core/safety.dart          faixas TWI, cores, rótulos
  lib/core/calibration.dart     CameraModel (fy, cy, Z0, θ, k) + calibrarK
  lib/vision/laser_profiler.dart port do algoritmo A + filtro temporal
  lib/depth/native_depth_view.dart canal e platform view do modo B
  lib/screens/measure_screen.dart  tela única
  android/app/src/main/kotlin/.../{MainActivity,ArDepthView,DepthMeasurer}.kt
  android/NOTAS_ANDROID.md      gradle + manifest
  ios/Runner/{AppDelegate,DepthMeasurer}.swift
```

---

## 2. Abordagem A — triangulação óptica

### 2.1 Montagem física (é ela que define a precisão)

```
         câmera do celular (olha perpendicular à banda)
               │ eixo óptico
               │           laser de linha
               │          ╱  (plano inclinado θ ≈ 30–40°)
               │        ╱
   Z0          │      ╱
   (gabarito)  │    ╱
               ▼  ╱
  ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀ topo dos blocos (linha em v_topo)
            █      █
            █ sulco█  d   ← fundo: a linha aparece deslocada (v_fundo)
            ████████
```

- Um **gabarito**, impresso em 3D, segura o celular e o chaveiro laser com
  distância Z0 e ângulo θ fixos. Ele tem dois pés que apoiam nos blocos.
- A **linha laser precisa cruzar os sulcos perpendicularmente**. Assim o plano
  de luz fica paralelo às paredes do sulco e elas não fazem sombra no fundo.
- Para a câmera:
  - Use exposição baixa (o app aplica −1,5 EV) para a linha não estourar.
  - Trave o foco na distância do gabarito (macro), porque o autofoco "caça"
    sobre a borracha escura.
  - Mantenha o flash desligado.
- Use um laser de 650 nm (vermelho) e 5 mW. Uma linha fina, de menos de 1 mm
  na distância de trabalho, melhora o centróide.

### 2.2 Modelo matemático

Use o modelo pinhole, com `v` (linha da imagem) medido a partir do ponto
principal `cy`. O laser é um plano que, sobre o bloco (Z = Z0), passa na
altura Y_L. No fundo do sulco (Z = Z0 + d), ele avança `d·tanθ`:

```
a = v_topo − cy          →  Y_L = a·Z0/fy
b = v_fundo − cy         →  b = fy·(Y_L + d·tanθ)/(Z0 + d)

Isolando d:   d = Z0 · (b − a) / (fy·tanθ − b)        (exata)

1ª ordem:     d ≈ Δv · (Z0/fy) / tanθ                 (Δv = b − a)
                   └ mm por pixel ┘
```

Na 1ª ordem, `Z0/fy` é o tamanho de um pixel no plano do pneu, e `1/tanθ`
amplifica o deslocamento. Exemplo: fy = 1400 px e Z0 = 80 mm dão
0,057 mm/px. Com θ = 35°, 1 px de deslocamento equivale a 0,082 mm de
profundidade. Com centróide subpixel de ~0,1 px, a resolução teórica fica
abaixo de 0,01 mm. O limite real vem da mecânica, da textura e da calibração.

A fórmula exata importa porque o fundo do sulco está mais longe da câmera.
Com d = 8 mm e Z0 = 80 mm, a perspectiva muda a escala em ~10 %, e a 1ª
ordem ignora isso.

**Escolha de θ:**

| Ângulo | Sensibilidade | Contrapartida |
|---|---|---|
| Maior (ex.: 45°) | mais px por mm | linha mais esticada, sombras em sulcos estreitos |
| Menor (ex.: 20°) | menos px por mm | mais robusto |

30–40° é um bom compromisso.

### 2.3 Algoritmo de imagem (passo a passo)

1. **Segmentação do laser.**
   - Em OpenCV (`tread_depth.py`), usa HSV com dois intervalos de vermelho,
     H 0–12 e 165–180. Aceita também o núcleo saturado quase branco, mas só
     quando ele está colado em pixels vermelhos. Isso evita pegar reflexos
     soltos na borracha.
   - No app (Dart), usa o canal Cr do YUV no Android (Cr ≥ 145) ou `R − max(G,B)`
     no iOS. O efeito é o mesmo, sem converter o quadro inteiro.
2. **Perfil subpixel.** Para cada coluna `u`, acha o pico e calcula o
   centróide ponderado numa janela de ±7 px. O resultado é `v(u)` com
   ~0,1 px de resolução.
3. **Referência (topo dos blocos).** Ajusta uma reta (ou parábola, para
   curvatura transversal) por mínimos quadrados, de forma iterativa:
   descarta os pontos que desviam mais de 1,5 px no sentido do sulco. Como o
   sulco só desvia para um lado, o ajuste converge para o nível dos blocos.
   Isso também corrige o celular levemente torto.
4. **Triangulação.** Para cada coluna, calcula
   `d(u) = k·Z0·(b−a)/(fy·tanθ − b)`.
5. **Segmentação dos sulcos.** São trechos contíguos com d > 0,5 mm e
   largura ≥ 15 px. Lacunas curtas sem laser são toleradas. As bordas (25 %
   de cada lado, transição e parede) são descartadas. A profundidade do sulco
   é a **mediana** da parte central, e a dispersão é o IQR.
6. **Filtro temporal (app).** Aplica a mediana das últimas 7 leituras. A
   leitura é marcada como "estável" quando todas ficam dentro de ±0,3 mm.
7. **Status.** O menor sulco define a cor geral, e cada sulco ganha seu chip.

Evite medir sobre a barrinha do TWI dentro do sulco. Ela é, por definição,
1,6 mm mais alta que o fundo.

### 2.4 Calibração

| Parâmetro | Como obter |
|---|---|
| `fy`, `cy` | Calibração de câmera com tabuleiro de xadrez (`cv2.calibrateCamera`) **na resolução do stream** (1280×720 no app). No Android dá para ler `LENS_INTRINSIC_CALIBRATION` da Camera2, quando disponível. |
| `Z0`, `θ` | Cotas do gabarito |
| `k` | Medir um **bloco-padrão** impresso/usinado com degraus conhecidos (ex.: 2, 5 e 8 mm) e rodar `calibrarK(medidos, reais)` |

O fator `k` é o passo que mais pesa. Os erros de θ, Z0 e fy são quase
puramente multiplicativos (veja §2.5), então um único fator corrige todos
juntos.

### 2.5 Validação feita (dados sintéticos)

`python simulate.py` gera fotos com sulcos de **8,0 / 4,5 / 2,4 / 1,2 mm**,
com textura de borracha, celular inclinado, ruído e compressão JPEG. Depois
confere a medição:

| Cenário | Medido (mm) |
|---|---|
| 5 imagens, ruído normal, JPEG 85 | 8,00 / 4,50 / 2,40 / 1,20 (erro máx. 0,00) |
| Ruído alto + JPEG 60 | 8,01 / 4,50 / 2,40 / 1,20 |
| Port Dart (caminho YUV420), transcrito | 8,00–8,01 / 4,49–4,50 / 2,39 / 1,19–1,20 |
| θ errado em +1° | 7,71 / 4,34 / 2,32 / 1,16 (−3,6 %) |
| Z0 errado em +2 mm | 8,21 / 4,61 / 2,46 / 1,23 (+2,6 %) |
| θ +2° e Z0 −2 mm, **após calibrar k** em outra imagem | 8,00 / 4,51 / 2,41 / 1,21 |

Os dados sintéticos validam a **lógica e a matemática**, não o mundo real.
A textura da borracha, a sujeira, as pedras no sulco e o espalhamento do
laser na borracha ainda precisam ser medidos em pneus reais, comparando com
um paquímetro de banda (§6).

Uso do script em foto real:

```bash
cd python
python tread_depth.py foto.jpg --fy 1400 --cy 540 --z0 80 --theta 35 --k 1.0
# gera anotada.png e imprime JSON com cada sulco e o status
```

---

## 3. Abordagem B — Depth API nativa

### 3.1 Acesso ao sensor

| | Android (ARCore) | iOS (ARKit) |
|---|---|---|
| Configuração | `Config.DepthMode.RAW_DEPTH_ONLY` | `frameSemantics = .smoothedSceneDepth` (ou `.sceneDepth`) |
| Profundidade | `frame.acquireRawDepthImage16Bits()` (mm, uint16) | `frame.smoothedSceneDepth.depthMap` (m, Float32, ~256×192) |
| Confiança | `acquireRawDepthConfidenceImage()` (0–255) | `confidenceMap` (low/medium/high) |
| Toque → pixel | `transformCoordinates2d(VIEW_NORMALIZED → TEXTURE_NORMALIZED)` | `displayTransform(for:viewportSize:).inverted()` |
| Intrínsecos | `camera.textureIntrinsics` (escalar p/ resolução do depth) | `camera.intrinsics` + `imageResolution` (escalar) |
| Disponibilidade | Aparelhos da lista da Depth API; ToF quando houver | Só com LiDAR (linhas Pro) |

### 3.2 Filtragem do ruído e medida no ponto tocado

Mesma lógica nos dois `DepthMeasurer`:

1. Converte o toque para o pixel do mapa de profundidade e calcula a escala
   local (mm/px = Z/fx). Acima de 2,5 mm/px retorna `TOO_FAR`.
2. Desprojeta para 3D um **disco central** (r ≤ 2 mm, o fundo do sulco) e um
   **anel** (7–14 mm, os blocos ao redor). Mantém só os pixels de confiança
   alta (ARKit `.high`, ARCore ≥ 200).
3. Ajusta um **plano robusto ao anel** (z = ax + by + c, 4 iterações
   mantendo o nível mais próximo). Isso remove a inclinação do celular e os
   sulcos vizinhos que caem no anel.
4. Profundidade do quadro = **mediana** da distância, ao longo da normal, dos
   pontos do disco até o plano.
5. Acumula **20 quadros** e retorna a mediana e a dispersão (IQR). O app só
   confia na leitura se o IQR for ≤ 1 mm. Fora disso, pede para confirmar
   com o laser.

### 3.3 Limitação (importante para o projeto)

Os sensores de profundidade de celular foram projetados para AR em escala de
ambiente. O mapa tem poucas centenas de pixels de largura, e o ruído típico
fica na casa do centímetro, ou de vários milímetros na melhor condição. Em
distâncias de 10–20 cm ainda entra a distância mínima de operação do sensor.
Uma diferença de 1,6 mm entre o fundo do sulco e o bloco fica, na prática,
**dentro do ruído**.

Por isso a Abordagem B, no MVP:

- distingue razoavelmente "sulco fundo (pneu novo)" de "quase liso", mas
  **não deve decidir o status do TWI sozinha**;
- é mais útil como **apoio à Abordagem A**: medir Z0 e a inclinação do
  celular automaticamente reduz a dependência do gabarito.

O código já está preparado para essa evolução: `DepthMeasurer` devolve
`distanceMm`.

---

## 4. Passo a passo de desenvolvimento

1. **Validar o algoritmo no PC.**
   - Rode `python simulate.py` (deve dar erro < 0,2 mm).
   - Tire 10–20 fotos reais com o celular no gabarito e rode `tread_depth.py`.
   - Ajuste os limiares HSV para o seu laser e a sua luz.
2. **Calibrar.**
   - Calibre a câmera com o tabuleiro na resolução 1280×720 para obter fy e cy.
   - Meça o bloco-padrão para obter `k`.
3. **Criar o projeto Flutter.**
   ```bash
   cd app
   flutter create --platforms=android,ios --org com.example .
   flutter pub get
   ```
   - Copie os arquivos de `lib/`, os `.kt` e os `.swift` deste repositório
     por cima dos gerados.
   - Aplique `android/NOTAS_ANDROID.md` e as entradas do Info.plist que estão
     no fim de `AppDelegate.swift`.
4. **Rodar o modo Laser.** Use `flutter run` num aparelho físico; o emulador
   não tem câmera útil. Confira a faixa-guia, a leitura em mm e o semáforo.
5. **Rodar o modo ToF/LiDAR.** Use um aparelho compatível. O botão fica
   desabilitado nos demais.
6. **Ajustar parâmetros** comparando com o paquímetro (§6):
   - `_janela`, `_tolRef` e `_minLargPx` em `laser_profiler.dart`;
   - o número de quadros e `PLANE_TOL_MM` no modo B.

**Não testado em aparelho.** Este código não foi compilado nem rodado em
celular. O ambiente usado não tinha SDK Flutter, Kotlin ou Xcode. O que foi
executado e validado é o algoritmo em Python e uma transcrição fiel do port
Dart sobre imagens YUV420. Espere pequenos ajustes de compilação, como
versões de dependências e APIs de platform view, na primeira build.

---

## 5. Próximos passos sugeridos

- **Tela de calibração no app:** medir o bloco-padrão, calcular `k` e salvar
  (`CameraModel.salvar` já existe).
- **Histórico por veículo/pneu** (posição DE/DD/TE/TD, data, foto anotada) e
  exportação em PDF/CSV.
- **Estimativa de desgaste irregular:** comparar sulcos interno, central e
  externo, o que indica problema de alinhamento ou calibragem.
- **Rede neural leve** (segmentação da linha) só se o HSV falhar em campo,
  por exemplo com sol forte. Nesse caso, um laser mais potente ou um filtro
  óptico de 650 nm na frente da câmera costuma resolver antes.

## 6. Protocolo de validação em campo

Meça 30 pneus, com 3 sulcos cada, com o app e com um paquímetro de banda
digital. Reporte:

- o viés médio;
- o desvio-padrão;
- a concordância nas três faixas de cor (matriz de confusão).

Critério sugerido para o MVP: |viés| < 0,3 mm, desvio < 0,4 mm e nenhum pneu
vermelho classificado como verde.
