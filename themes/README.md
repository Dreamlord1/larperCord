# Escrevendo temas

Um tema do larperCord é um arquivo [KDL](https://kdl.dev) que descreve **a interface inteira**:
cores, fontes, estilos e a árvore de layout. Dá pra mudar a posição de tudo sem escrever
uma linha de código.

Coloque o arquivo em `~/.config/larpercord/themes/meu-tema.kdl` (ou em `themes/`, ao rodar
de dentro do repositório). **Ao salvar, o app recarrega na hora.** Se houver um erro, aparece
um aviso com `arquivo:linha:coluna` e o tema anterior continua valendo.

Troque de tema com `F2`, pela paleta (`Ctrl+K` → "tema: …") ou em Configurações → Aparência.

## Exemplo mínimo

```kdl
theme "meu-tema" description="Servidores embaixo, chat em cima." preview=classic
palette "wal"                      // usa as cores do pywal (opcional)

colors {
    accent "wal:4"
    surface "mix(wal:0, black, 0.2)"
}

layout {
    column {
        row flex=1 {
            channel-list width=240 bg=sidebar
            column flex=1 {
                messages flex=1
                composer height=46 inset-x=16 inset-y=4
            }
        }
        guild-bar height=60 orientation=horizontal
    }
}
```

## Nós de topo

| Nó | O que faz |
|---|---|
| `theme "nome" description=… author=… preview=…` | metadados. `preview` escolhe a miniatura nas configurações: `classic`, `glass`, `terminal`, `bubbles`, `zen`, `dock`, `mirror`, `gameboy`, `office` |
| `palette "wal"` ou `palette "#hex" …` | as 16 cores base (`wal:0` … `wal:15`). Sem isso, usa uma paleta padrão |
| `colors { token "expressão" … }` | sobrescreve tokens de cor (lista abaixo) |
| `roles "cor" …` | até 8 cores de cargo (nomes de usuário, ícones de servidor) |
| `fonts ui="Inter" mono="JetBrains Mono" size=16` | famílias (resolvidas pelo fontconfig) e tamanho base |
| `metrics radius=6` | arredondamento padrão de linhas e botões |
| `window transparent=#true` | fundo da janela transparente: o compositor aplica blur |
| `styles { style "nome" … }` | estilos nomeados para usar com `style=nome` |
| `layout { … }` | a árvore da interface (um único filho na raiz) |

## Cores

Expressões aceitas em qualquer lugar que pede cor:

```
"#df68ad"   "#df68ad80"   "#fff"   "#fff8"
"wal:4"                    cor da paleta
"@surface"                 outro token (já definido)
"mix(a, b, 0.3)"           mistura
"alpha(a, 0.5)"            transparência
"lighten(a, 0.1)"  "darken(a, 0.2)"
white  black  transparent
```

Tokens: `bg` `rail` `sidebar` `surface` `elevated` `overlay` `text` `muted` `faint` `accent`
`accent-text` `border` `hover` `selected` `online` `idle` `dnd` `danger` `mention` `link`
`code-bg` `bubble-self` `bubble-self-text` `bubble-other` `shadow`.

## Estilos

```kdl
styles {
    style "card" bg="@surface" radius=18 border="@border" border-width=1.5 glow="@accent" shadow=16
}
```

`glow` é a cor da borda quando o mouse está em cima. `shadow` é o tamanho da sombra.
Para um fundo simples, sem estilo nomeado, use direto no nó: `bg=sidebar radius=12`.

## Layout

Contêineres: `row` (horizontal), `column` (vertical), `stack` (um sobre o outro).

| Propriedade | Efeito |
|---|---|
| `width=` / `height=` | tamanho fixo no eixo do pai |
| `flex=` | peso no espaço que sobra (padrão 1) |
| `gap=` `padding=` `padding-x=` `padding-y=` | espaçamentos (contêineres) |
| `inset-x=` `inset-y=` | margem interna de um componente |
| `max-width=` | limita a largura e centraliza |
| `hide-below=` | esconde quando a janela é mais estreita que isso |
| `show=#false` | esconde |
| `style=` / `bg=` `radius=` | fundo do nó |
| `font=mono` / `font=ui` / `font="Liberation Serif"` | fonte do componente: a mono, a da interface ou **qualquer família instalada** |
| `c-<token>=cor` | sobrescreve um token de cor **neste nó e nos filhos** (ex.: `c-text="#fff"` numa barra lateral escura) |

## Componentes

| Componente | Propriedades |
|---|---|
| `guild-bar` | `variant=bar\|dock\|list` `icon-style=fill\|soft\|outline` `orientation=vertical\|horizontal` `shape=circle\|squircle\|square\|text` `size=48` `labels=#true` `home=#false` |
| `channel-list` | `variant=discord\|tree\|pills` `header=#false` |
| `user-panel` | `variant=discord\|tty` |
| `header` | `variant=discord\|minimal\|tty` `divider=#false` |
| `tabs` | `variant=pills\|underline\|tty` |
| `messages` | `variant=cozy\|irc\|bubbles` `avatar=circle\|squircle\|square\|none` `avatar-size=40` `spacing=16` `font-size=` |
| `composer` | `variant=box\|pill\|prompt` `typing=#false` |
| `member-list` | `variant=discord\|tty` |
| `status-bar` | `variant=pills\|tty\|plain` `items="conn ping ram frame voice spacer theme keys clock"` |
| `label` | `text=` `size=` `weight=regular\|medium\|semibold\|bold` `color=token` `align=left\|center\|right` |
| `spacer` | espaço vazio |

Um nome que não existe aparece com uma borda vermelha e a linha do arquivo, pra facilitar.

## Os temas que vêm junto

- [`classico.kdl`](classico.kdl): o layout familiar
- [`vidro.kdl`](vidro.kdl): cartões translúcidos com blur do compositor
- [`terminal.kdl`](terminal.kdl): tmux + IRC em fósforo âmbar
- [`bolhas.kdl`](bolhas.kdl): claro, com balões de conversa
- [`zen.kdl`](zen.kdl): uma coluna central e mais nada
- [`neon.kdl`](neon.kdl): synthwave com dock que cresce no mouse (`variant=dock`)
- [`papel.kdl`](papel.kdl): serifado e espelhado
- [`gameboy.kdl`](gameboy.kdl): quatro tons de verde
- [`escritorio.kdl`](escritorio.kdl): estilo Slack, mostra o `c-…` e o `variant=list`

Os testes (`zig build test`) carregam todos os temas embutidos e montam o layout de cada um.
Se você mandar um tema novo num pull request, ele é verificado automaticamente.

## Dicas de design

O que separa um tema bonito de um tema estranho quase nunca é a cor de destaque. Normalmente é:

- **Um conceito só.** "Caderno", "terminal", "portátil de 1989"… e tudo segue ele: cores,
  fonte, cantos e bordas.
- **Superfícies que se separam.** Fundo, painéis e elementos elevados precisam de degraus de
  luminosidade claros. Roxo sobre roxo sobre roxo vira uma massa só.
- **Poucas cores acesas.** Uma de destaque e, no máximo, uma secundária. Use `roles` com cores da
  mesma família para os nomes não virarem um arco-íris.
- **Uma fonte de texto**, e no máximo uma de títulos (`header … font="Liberation Serif"`).
- **Contraste suficiente** para `text`, `muted` e `faint` sobre o fundo de cada painel. Use `c-…`
  quando um pedaço do layout tem fundo bem diferente (barra lateral escura num tema claro).
