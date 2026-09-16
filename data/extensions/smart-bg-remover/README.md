# Removedor de Fundo Inteligente (Smart Background Remover)

Extensão do Aseprite que **reconhece o padrão do fundo** de uma imagem e remove
esse fundo de **todos os frames selecionados na timeline** de uma vez, dentro de
uma única transação (um `Ctrl+Z` desfaz tudo).

## Como usar

1. Selecione os frames na timeline (ou os cels).
2. Clique com o **botão direito** sobre a seleção.
3. No menu de contexto, escolha **Fundo Inteligente** e depois:
   - **Remover fundo…** – abre o diálogo de opções e executa;
   - **Analisar fundo (sem alterar)** – apenas informa o padrão detectado e quantos
     pixels seriam apagados (ótimo para achar a tolerância certa antes de aplicar);
   - **Repetir última remoção** – repete com as opções da última vez, sem diálogo.

O mesmo submenu aparece no menu de contexto dos **cels**.

## O que ele reconhece

O núcleo (`lib/bgcore.lua`) amostra uma faixa na borda da imagem e classifica o
fundo em um destes modelos:

| Modelo | Quando é usado | Como decide o que apagar |
|---|---|---|
| `flat` | uma cor domina ≥ 80% da borda | correspondência dessa cor (com tolerância) |
| `tile` | a borda tem um padrão que se repete (xadrez, listras, tramas de dither tipo Bayer) | detecta o tile (1×1, 2×1, 1×2, 2×2, 4×4, 8×8, 16×16) e prevê a cor esperada em **cada posição** `(x % P, y % Q)` – por isso não vaza para dentro do sujeito nem deixa resto de xadrez |
| `gradient` | a borda varia suavemente | ajusta um plano por mínimos quadrados e compara cada pixel com o valor previsto |
| `set` | fundo complexo/sem estrutura (ruído, foto) | conjunto das cores principais da borda |
| `transparent` | a borda já é transparente | não faz nada |

Quando o modelo é incerto (`set`/`flood`), a opção **“Apagar somente áreas
conectadas às bordas”** (ligada por padrão) faz uma inundação em 4-conexão a
partir da borda, para não apagar pixels do sujeito que por acaso tenham a mesma
cor do fundo.

## Opções do diálogo

- **Detecção** – força um modelo específico (`Automático` tenta todos, nesta
  ordem: plano → padrão/tile → gradiente → conjunto).
- **Tolerância** – distância euclidiana RGBA aceita (0 a 128). Valores maiores
  apagam mais, mas podem comer detalhes do sujeito.
- **Suavizar bordas** – cria uma transição de alpha nos pixels de borda que
  estão “quase” na cor do fundo (0 desliga).
- **Apagar somente áreas conectadas às bordas** – segurança extra.
- **Apagar também ilhas internas do fundo** – remove buracos da cor do fundo que
  ficaram presos dentro do sujeito.
- **Amostragem da borda** – espessura da faixa e quais lados amostrar (útil
  quando só um lado é fundo).
- **Escopo** – frames selecionados / frame atual / todos os frames.
- **Camadas** – camada ativa / todas / apenas visíveis.
- **Detectar o fundo em cada frame** – desmarque para detectar uma única vez no
  primeiro frame e reusar o modelo nos demais (bem mais rápido em sequências
  com o mesmo fundo).

As opções ficam salvas em `preferences.lua` e reaparecem na próxima vez.

## Desempenho

O processamento é feito em cima dos bytes brutos da imagem com tabelas de
consulta memoizadas, sem laço por pixel em Python/C++. Referência medida com
Lua 5.5 fora do Aseprite: **~0,5 s por frame 2048×2048** (4,2 M px), incluindo
análise do padrão, máscara e escrita do resultado.

## Instalação

Copie a pasta `smart-bg-remover` para a pasta de extensões do Aseprite
(`Editar > Preferências > Extensões > Abrir Pasta`) e reinicie o Aseprite.
Esta pasta também funciona como extensão embutida dentro de
`data/extensions/` do código-fonte do Aseprite.

## Arquivos

```
smart-bg-remover/
  package.json         metadados da extensão
  main.lua             comandos, menus e diálogo (camada Aseprite)
  lib/bgcore.lua       núcleo do algoritmo (puro, sem dependências do Aseprite)
  test/                harness de auditoria (não é necessário para usar)
```

## Auditoria / testes

A pasta `test/` roda o algoritmo fora do Aseprite, compara o resultado com uma
máscara verdade e gera imagens de conferência:

```bash
pip install numpy pillow lupa
python3 test/harness.py              # 10 casos sintéticos com ground truth
python3 test/harness.py --size 2048  # os mesmos casos em 2K (mede o tempo)
python3 test/harness.py --integration  # main.lua inteiro com Aseprite simulado
python3 test/harness.py --real CAMINHO_DAS_IMAGENS   # suas imagens reais
```

Cada caso gera em `test/results/` um tríptico `antes | depois | auditoria`, onde o
painel de auditoria mostra em verde o fundo removido corretamente, em vermelho
o dano no sujeito e em amarelo o fundo que sobrou.
