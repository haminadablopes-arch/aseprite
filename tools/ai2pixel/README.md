# ai2pixel — Metodologia **Grade-Nativa** (Native-Grid Fidelity Pipeline)

Converte imagens *pseudo pixel art* geradas por IA (DALL·E, Gemini, Midjourney,
SD etc.) em **pixel art autêntica**, preservando a identidade visual, a
composição e a paleta do original, na **resolução nativa de cada pixel**:
1 bloco de pseudo-pixel detectado na fonte = 1 pixel real no resultado.

> Por que não basta "reduzir e quantizar": renders de IA entregam blocos
> fora de grade (pitch fracionário, fase deslocada), 300+ cores, gradientes,
> ruído de codec e blur nas bordas. Um downscale bicúbico + quantização ingênua
> produz "foto em baixa resolução", não sprite. A metodologia abaixo resolve
> cada um desses defeitos na ordem certa.

---

## Os 7 estágios

### 0 · Diagnóstico
Contagem de cores únicas, detecção de fundo sólido (chroma-key) pela moldura
externa (cor modal quantizada, cobertura > 30% e saturação > 60) e medição da
energia de gradiente por coluna/linha (sinal de arestas com alpha pré‑multiplicado).

### 1 · Chroma-key + despill
Alpha com borda suave (`d ∈ [0.45·tol, 1.05·tol]`) em distância RGB e *despill*:
o canal dominante do fundo é limitado pelos outros dois, removendo a franja
verde/ciano/magenta das silhuetas **antes** de qualquer amostragem — assim as
medianas das células nunca são contaminadas pelo fundo.

### 2 · Detecção da grade (pitch fracionário + fase)
Os pseudo-pixels formam um pente de fronteiras. A detecção combina três
estimadores robustos, no espírito do *tiled voting* do unfake.js e da detecção
de block-size de Seo et al. (2026):

1. **Picos de fronteira** — picos locais do sinal de arestas acima de limiar
   relativo ao conteúdo (fundos vazios são excluídos por máscara de conteúdo);
2. **RANSAC de pares** — hipóteses `pitch = (b_j − b_i)/m` votam inliers com
   fase circular; tolerância escalada com o pitch (`max(0.6, min(1.2, 0.15p))`)
   evita degenerescência em pitches minúsculos;
3. **Regressão global robusta** — mediana de inclinações (estilo Theil–Sen) +
   mínimos quadrados só nos inliers: estima `pitch` e `fase` imunes a drift
   local de blur/JPEG; varredura fina (0.02 px) com fase = mediana circular.

Como pseudo-pixels de IA são quadrados, o eixo mais confiável serve de
referência e o outro é reajustado numa janela de ±6%.

### 3 · Reamostragem nativa (mediana no miolo)
Cada célula nativa `[φ + k·p, φ + (k+1)·p)` é amostrada e sua cor
representativa é a **mediana por canal dos pixels com alpha > 127 restrita ao
miolo central (56%) da célula** — as bordas carregam pixels misturados pelo
blur/upscaling e viesariam a cor. Ocupação < 45% ⇒ pixel transparente.
Isso equivale, de forma determinística e barata, à ideia de *outline expansion*
do PixelOE (preservar o detalhe de alto contraste antes de reduzir), mas sem
dilatar silhuetas: a mediana no miolo já rejeita ringing e ruído.

### 4 · Paleta global em OKLab (fidelidade absoluta quando possível)
* **Paleta exata**: as cores representativas recorrentes (contagem ≥ 3) são
  agrupadas num raio RGB ≤ 10 (centro = mediana do grupo). Se o número de
  grupos ≤ máx. de cores, a paleta do sprite **é a própria identidade cromática
  da arte** — quantização sem perda alguma;
* **Senão**, k-means (inicialização k-means++) no espaço perceptual **OKLab**
  (Ottosson, 2020), que respeita a percepção humana de diferença de cor;
* A paleta é **única e compartilhada por todos os frames** de uma animação:
  o encaixe determinístico por vizinho mais próximo elimina flicker de paleta
  entre frames (estabilidade temporal), o mesmo objetivo das técnicas de
  paleta compartilhada/histerese usadas em pipelines de sprite de vídeo.

### 5 · Encaixe, limpeza e dithering opcional
* Snap de cada pixel nativo ao centro de paleta mais próximo em OKLab;
* **Remoção de órfãos**: pixel cuja cor não aparece nos 4-vizinhos e cujo modo
  8-vizinho cobre ≥ 4 posições vira o modo (mata ruído pontual de IA sem
  apagar pixels isolados intencionais, que permanecem cercados de vazio);
* Dithering opcional Bayer 4×4 modulado em OKLab (desligado por padrão:
  sprites de personagem ficam mais limpos sem dither).

### 6 · Refinamento de alinhamento (sem ground truth)
Duas buscas locais maximizam métricas intrínsecas:
* **Pureza de célula** — fração de pixels que concordam com a mediana da própria célula;
* **Compacidade de paleta** — distância média das cores representativas aos
  centros modais. Ambas pico/vale exatamente quando a grade casa com os blocos
  reais (pitch ±0.06 px, fase ±2 px).

### 7 · Exportação nativa e métricas
PNG 1:1 por frame, folha de sprites horizontal, preview nearest-neighbor ×N,
GIF89a com transparência e loop (encoder LZW próprio, regra de largura de
código validada contra o decoder de referência), paleta `.gpl`/`.act`/PNG e
`report.json` com: pitch/fase/confiança/pureza/compacidade, tamanho nativo,
cores únicas, paleta exata?, ΔE médio de quantização, órfãos removidos e delta
de histograma entre frames (flicker).

---

## Como usar

### Studio web (recomendado — roda 100% no navegador, nada é enviado a servidores)
```bash
cd tools/ai2pixel/studio
python3 -m http.server 8090 --bind 0.0.0.0     # ou qualquer servidor estático
```
Abra `http://localhost:8090`, arraste as imagens (frames em ordem alfabética
viram animação), ajuste parâmetros e exporte: ZIP de frames PNG nativos,
sprite sheet, GIF, paletas `.gpl`/`.act` e relatório JSON.

### CLI Python (lote, reproduzível)
```bash
pip install -r tools/ai2pixel/requirements.txt
python3 tools/ai2pixel/pipeline/ai2pixel.py -i frames/*.png -o out/ \
        --max-colors 32 --chroma auto --tol 90 --cleanup 1 --fps 12
```
Principais opções: `--max-colors N` (teto da paleta; abaixo disso a paleta é
exata), `--chroma auto|off|#RRGGBB`, `--tol`, `--cleanup 0|1|2`,
`--dither off|bayer`, `--pitch N` (força a grade), `--preview-scale N`.

### Validação (teste round-trip)
```bash
python3 tools/ai2pixel/pipeline/roundtrip_test.py   # Python
node tools/ai2pixel/studio/test_node.mjs             # port JS
```
O teste gera um ground truth nativo (48×64, 4 frames, paleta fechada), degrada
do jeito que uma IA degrada — pitch fracionário 9.4 px, fase (37, 53), blur
gaussiano, ruído σ=5, fundo chroma verde, JPEG q92 — e exige que o pipeline
recupere bbox exata, paleta exata e ≥ 78% de cor exata (±8) por pixel.
Resultado medido: **~80–81% de cor exata sob JPEG+ruído** e **paleta/bbox 100%
recuperadas**; com entrada PNG sem perdas (o caso real das imagens de IA), a
fidelidade sobe para ~95–100%, pois a etapa 4 torna a quantização não-destrutiva.

### Integração com Aseprite
* Abra os `frames_native/*.png` direto no Aseprite (já estão 1:1);
* Carregue `palette.gpl` em *Editar → Paleta* (ou `palette.act`);
* Automação: `aseprite -b sprite_sheet.png --split-grid 0,0,LARGURA,ALTURA
  --palette palette.gpl --save-as anim.aseprite` (CLI oficial);
* Ou use o script Lua incluso:
  `aseprite -b --script tools/ai2pixel/aseprite/ai2pixel_import.lua
  --script-param dir=out/frames_native --script-param count=16
  --script-param gpl=out/palette.gpl --script-param out=personagem.aseprite`.
  Como as cores já são membros exatos da paleta, *Sprite → Color Mode →
  Indexed* depois disso é um clique sem perda.

---

## Limitações conhecidas
* Grades < 3 px ou imagens sem estrutura de blocos (foto real) caem no ramo
  "já nativa"/k-means — use o PixelOE ou o PIA de Gerstner et al. para
  fotorrealismo;
* Frames com movimento muito rápido podem precisar de `--cleanup 0` para
  preservar detalhes de 1 px legítimos;
* O chroma-key assume fundo sólido; fundos fotográficos exigem recorte prévio.

## Referências
1. Yeh, S.-Y. *PixelOE: Detail-Oriented Pixelization based on Contrast-Aware
   Outline Expansion* (2024) — github.com/KohakuBlueleaf/PixelOE
2. Gerstner, DeCarlo, Alexa, Finkelstein, Gingold, Nealen. *Pixelated Image
   Abstraction*, NPAR 2012; *…with integrated user constraints*, Computers &
   Graphics 37(5), 2013
3. Seo, Lee, Lee, Kim, Jung. *Structure-Aware Pixel Art Scaling via Block Size
   Detection*, Applied Sciences 16(5):2314, 2026
4. jenissimo. *unfake.js / Unfaker* — detecção de grade por votação de blocos
   (github.com/jenissimo/unfake.js)
5. Kopf, Lischinski. *Depixelizing Pixel Art* (problema inverso), 2011
6. Ottosson, B. *A perceptual color space for image processing* (OKLab), 2020
7. Floyd, Steinberg. *An adaptive algorithm for spatial grey scale*, 1976;
   Bayer, B. *An optimum method for two-level rendition*, 1973
8. Aseprite CLI/API — aseprite.org/docs/cli
9. Binninger et al. *SD-πXL* (arXiv:2410.06236) — por que **não** usar difusão
   para esta tarefa: fidelidade absoluta exige pipeline determinístico
