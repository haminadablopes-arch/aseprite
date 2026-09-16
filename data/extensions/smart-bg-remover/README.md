# Removedor de Fundo Inteligente (Smart Background Remover) v0.5.0

Extensão do Aseprite que **reconhece o padrão do fundo** e remove esse fundo de **todos os frames selecionados** com **preview ao vivo no canvas** e reaproveitamento de layer.

Novo fluxo (v0.5.0):
- Só 2 layers: `Original` (oculta após processar) + `Original - removido` (sempre sobrescrita, nunca cria nova a cada vez)
- **Preview ao vivo no próprio canvas**: ao abrir (Ctrl+Shift+B), o primeiro frame selecionado é processado e mostra instantaneamente no canvas enquanto você mexe nos sliders
- Após confirmar, aplica a todos os frames selecionados **sem diálogo de relatório** (apenas oculta a original e mostra a processada, desfaz com Ctrl+Z)
- Atalho **Ctrl+Shift+B** abre direto o modo preview

## Como usar

1. Selecione os frames na timeline (ou deixe só o frame atual ativo).
2. Pressione **Ctrl+Shift+B** ou clique com botão direito sobre a seleção > **Fundo Inteligente** > **Preview Remoção de Fundo (Ctrl+Shift+B)**
3. No diálogo de preview, ajuste:
   - **Detecção**: Automático, Cor sólida, Padrão repetitivo, Gradiente, etc.
   - **Tolerância**: 0-128
   - **Suavizar bordas**: 0-64
   - **Detectar fundo em cada frame ao confirmar**: marcado = re-analisa cada frame (mais preciso se fundo muda), desmarcado = usa o mesmo modelo do primeiro frame para todos (muito mais rápido)
4. O resultado aparece **instantaneamente no canvas** no primeiro frame.
5. Clique **Confirmar e aplicar a todos** para processar o resto dos frames. Ou **Cancelar** para desfazer o preview.

O mesmo submenu aparece no menu de contexto dos **cels**.

Outros comandos:
- **Repetir última remoção**: repete com as opções salvas, sem abrir preview, reutilizando a layer ` - removido`.

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

Tolerância, suavização, modo, etc. ficam salvas em `preferences.lua`. No preview mostramos só os essenciais para teste rápido, mas as opções avançadas (contíguo, ilhas, espessura da borda, lados) continuam salvas e usadas no processamento final.

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
