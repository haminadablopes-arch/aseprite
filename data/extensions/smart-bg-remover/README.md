# Removedor de Fundo Inteligente (Smart Background Remover) v0.6.1

Extensão do Aseprite que **reconhece o padrão do fundo** e remove esse fundo de **todos os frames selecionados** com **preview ao vivo no canvas** e reaproveitamento de layer.

Novo fluxo (v0.6.0):
- Só 2 layers: `Original` (oculta após processar) + `Original - removido` (sempre sobrescrita, nunca cria nova a cada vez)
- **Preview ao vivo no próprio canvas de TODOS os frames selecionados**: ao abrir (Ctrl+Shift+B), todos os frames do escopo são processados e o resultado aparece no canvas — aperte **play** (ou o botão ▶ do diálogo) para conferir a animação inteira antes de confirmar
- **Sem travar**: durante o arraste dos sliders só o 1º frame é reprocessado (instantâneo); ao soltar (onrelease) o lote inteiro é atualizado em parcelas de ~50ms via Timer, mantendo a UI responsiva
- Após confirmar, aplica a todos os frames selecionados **sem diálogo de relatório** (apenas oculta a original e mostra a processada, desfaz com Ctrl+Z)
- Atalho **Ctrl+Shift+B** abre direto o modo preview

## Como usar

1. Selecione os frames na timeline (ou deixe só o frame atual ativo).
2. Pressione **Ctrl+Shift+B** ou clique com botão direito sobre a seleção > **Remover fundo (Ctrl+Shift+B)**
3. No diálogo de preview, ajuste (tudo com atualização instantânea no canvas):
   - **Detecção**: Automático, Cor sólida, Padrão repetitivo, Gradiente, etc.
   - **Tolerância**: 0-128
   - **Suavizar bordas**: 0-64
   - **Apagar somente áreas conectadas às bordas**
   - **Apagar também ilhas internas**
   - **Amostragem da borda**: **Espessura** (1-32) e lados **Topo / Base / Esquerda / Direita**
   - **Detectar fundo em cada frame ao confirmar**: marcado = re-analisa cada frame (mais preciso se fundo muda), desmarcado = usa o mesmo modelo do primeiro frame para todos (muito mais rápido). Este só afeta a confirmação final.
4. O resultado aparece **instantaneamente no canvas** no primeiro frame.
5. Clique **Confirmar e aplicar a todos** para processar o resto dos frames. Ou **Cancelar** para desfazer o preview.

O mesmo item aparece no menu de contexto dos **cels** (v0.6.1: um único item direto no popup, sem submenu; o preview abre sempre com as opções salvas da última execução, então "Repetir última remoção" foi removido).

## O que ele reconhece

O núcleo (`lib/bgcore.lua`) amostra a borda e classifica em:

| Modelo | Quando | Como decide |
|---|---|---|
| `flat` | uma cor domina ≥80% da borda | correspondência dessa cor |
| `tile` | padrão que se repete (xadrez, listras, dither Bayer) | detecta tile 1x1 até 16x16 e prevê cor por posição `(x%P, y%Q)` |
| `gradient` | variação suave | plano por mínimos quadrados |
| `set` | fundo complexo/ruído | conjunto de cores principais |
| `transparent` | borda já transparente | nada |

## Opções salvas

Tolerância, suavização, modo, etc. ficam salvas em `preferences.lua`. Desde a v0.5.1, **todos** os parâmetros (contíguo, ilhas, espessura da borda e lados) aparecem no preview e qualquer mudança atualiza o canvas imediatamente; ao confirmar, tudo é salvo e reutilizado pelo "Repetir última remoção".

## Preview de todos os frames e desempenho

Custo medido por frame (Lua 5.5, borda xadrez + assunto):

| Tamanho | analyze | process | total/frame |
|---|---|---|---|
| 64×64 | ~1,6ms | ~0,8ms | ~2,4ms |
| 256×256 | ~7ms | ~6ms | ~13ms |
| 512×512 | ~16ms | ~23ms | ~39ms |
| 1024×1024 | ~41ms | ~88ms | ~128ms |
| 2048×2048 | ~102ms | ~320ms | ~422ms |

Para manter a UI fluida:

- **Arraste de slider** → reprocessa só o 1º frame (resposta imediata).
- **Soltar o slider (onrelease), checkboxes e combobox** → atualiza o lote inteiro em parcelas de ~50ms (Timer), com progresso no status ("Atualizando previews... 3/10 frames"). Entre uma parcela e outra o Aseprite respira (redesenha, responde a cliques).
- **"Detectar fundo em cada frame ao confirmar" desligado** → o modelo do 1º frame é analisado uma única vez e reutilizado nos demais frames (economiza o analyze de cada um).
- **Cels vinculados** (frames que compartilham a mesma imagem) → processados uma única vez e propagados para todos os frames que os usam, na preview e na confirmação.
- **Cancelar** → restaura o conteúdo pré-preview de todos os cels tocados (ou remove os que foram criados só para a preview).
- O botão **▶ Reproduzir animação** roda o play do Aseprite com os previews aplicados; a própria reprodução não custa nada além do desenho normal (os cels já estão processados).

## Camadas

- Antes: criava `Nome (backup)` + `Nome` novo a cada execução.
- Agora: cria `Nome - removido` uma vez e **sempre sobrescreve** os cels selecionados. A original é ocultada (`isVisible=false`) após processar. Se rodar de novo, atualiza a mesma layer. Undo único desfaz tudo.

Isso evita poluição de layers e dá preview limpo.

## Atalho

Definido em `keys.aseprite-keys`:
- `Ctrl+Shift+B` → `SmartBgRemoverPreview` / `SmartBgRemoverCelPreview` / `SmartBgRemoverGlobalPreview`

Você pode mudar em Editar > Atalhos de Teclado.

## Desempenho

Processamento em bytes brutos com LUTs memoizadas. ~0,5s por frame 2048x2048 em Lua 5.5. Preview processa só 1 frame, então é instantâneo mesmo em sprites grandes.

## Arquivos

```
smart-bg-remover/
  package.json           metadados + keys
  keys.aseprite-keys     atalho Ctrl+Shift+B
  main.lua               comandos, preview ao vivo, reaproveitamento de layer
  lib/bgcore.lua         núcleo puro (sem API Aseprite)
  test/                  harness de auditoria
```

## Testes

```bash
pip install numpy pillow lupa
python3 test/harness.py
python3 test/harness.py --size 2048
python3 test/harness.py --integration
```
