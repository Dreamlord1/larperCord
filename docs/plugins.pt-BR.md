# Plugins em Lua

[English](plugins.md) · **Português**

Plugins são scripts pequenos que reagem ao que acontece no app e criam comandos e atalhos,
sem recompilar nada. Cada arquivo `.lua` em

```
~/.config/larpercord/plugins/          ($XDG_CONFIG_HOME/larpercord/plugins, se definido)
```

é um plugin. Abra **Configurações → Plugins** (`Ctrl+,`) para ver a lista, ligar e desligar cada um
(a escolha fica em `~/.config/larpercord/plugins.kdl`), ver o erro de quem quebrou e
**Recarregar** depois de editar um arquivo.

## Um exemplo

```lua
-- ~/.config/larpercord/plugins/shrug.lua
larper.command("/shrug", function(args)
  local texto = "¯\\_(ツ)_/¯"
  if args ~= "" then texto = args .. " " .. texto end
  larper.send(larper.channel(), texto)
end)
```

Digite `/shrug sei lá` na caixa de mensagem e o canal recebe `sei lá ¯\_(ツ)_/¯`. O `/shrug` em si
nunca vai para o Discord.

Os exemplos completos estão em [`docs/plugins/`](plugins/):

| Plugin | O que faz |
|---|---|
| [`shrug.lua`](plugins/shrug.lua) | `/shrug`: o comando acima |
| [`alerta.lua`](plugins/alerta.lua) | avisa quando alguém escreve uma palavra da sua lista |
| [`dado.lua`](plugins/dado.lua) | `/dado 2d20+3`, `/moeda` e `/escolhe pizza, sushi`, com o resultado no canal |
| [`zoeira.lua`](plugins/zoeira.lua) | `/mock`, `/vapor`, `/palmas`, `/contrario` e `/spoiler` reescrevem o texto |
| [`calc.lua`](plugins/calc.lua) | `/calc 2+3*4` responde só para você; `/conta` manda no canal. Um analisador feito à mão, bom modelo para sintaxe própria |
| [`relogio.lua`](plugins/relogio.lua) | `/hora tokyo`, `/horario lisboa` e um `/cronometro` (também em `Ctrl+Alt+T`) |
| [`resumo.lua`](plugins/resumo.lua) | `/resumo` (ou `Ctrl+Alt+R`): quantas mensagens, quem mais falou e onde, desde que o app abriu |

Para instalar: **Configurações → Plugins → Instalar exemplos** copia os que faltam para a sua pasta
(sem sobrescrever o que você já editou). Ou, à mão:
`mkdir -p ~/.config/larpercord/plugins && cp docs/plugins/*.lua ~/.config/larpercord/plugins/`
e **Recarregar**.

## API

Tudo fica na tabela global `larper`. IDs do Discord são strings (`"1234567890"`).

### `larper.on(evento, função)`

| evento | quando | argumento |
|---|---|---|
| `"message"` | chega uma mensagem nova em qualquer canal (inclusive as suas) | `msg` |
| `"ready"` | o app conectou (ou o plugin foi carregado/ligado com o app já conectado) | nenhum |

`msg` tem:

| campo | exemplo |
|---|---|
| `msg.content` | `"bom dia"` |
| `msg.author` | `{ id = "1001", name = "ana" }` |
| `msg.channel` | `{ id = "5000", name = "geral" }` |
| `msg.guild` | `{ id = "500", name = "Servidor" }`, ou `nil` em mensagens diretas |
| `msg.mine` | `true` se foi você que mandou |
| `msg.id` | `"1350000000000000000"` |

O histórico carregado ao abrir um canal não dispara `"message"`, só o que chega ao vivo.
Mensagens de sistema (fulano entrou, fixou…) também não.

```lua
larper.on("message", function(msg)
  if not msg.mine and msg.content:lower():find("pizza", 1, true) then
    larper.notify(msg.author.name .. " falou de pizza em #" .. msg.channel.name)
  end
end)
```

### `larper.command("/nome", função(args))`

Um comando local: quando você manda uma mensagem que começa com `/nome`, a função roda com o
resto do texto (`args`, sem espaços nas pontas, `""` se não tiver nada) e **nada vai para o
Discord**. O nome é `/` seguido de letras, números, `_` ou `-` (até 32). Se dois plugins
registrarem o mesmo nome, vale o primeiro em ordem alfabética do arquivo. Um `/algo` que nenhum
plugin ligado conhece vai como texto normal.

### `larper.keybind("ctrl+shift+x", função)`

Um atalho de teclado. Modificadores: `ctrl`, `shift`, `alt`, `super`; teclas: `a`–`z`, `0`–`9`,
`f1`–`f24`, `enter`, `space`, `tab`, `backspace`, `delete`, `insert`, `home`, `end`, `pageup`,
`pagedown`, `up`, `down`, `left`, `right`, `,` `.` `/` `;` `-` `=`. Letras e números precisam de
`ctrl`, `alt` ou `super` (senão disparariam enquanto você digita); as teclas F podem ir sozinhas.
O atalho vale fora das configurações e da paleta de comandos, inclusive com a caixa de texto em foco.
Os atalhos do app (`Ctrl+K`, `Ctrl+W`…) continuam funcionando junto: escolha outra combinação.

### `larper.notify(texto)`

Mostra um aviso no topo da janela. Com a janela fora de foco (e "Notificações na área de
trabalho" ligadas), também sai uma notificação do sistema.

### `larper.send(canal, texto)`

Manda uma mensagem de verdade, como se você tivesse digitado. `canal` pode ser `nil` (o canal
aberto), uma tabela com `id` (como `larper.channel()` ou `msg.channel`) ou o ID em string.
`texto` tem de 1 a 2000 bytes. No máximo 5 por comando/atalho.

> [!IMPORTANT]
> **`larper.send` só funciona dentro de um `larper.command` ou `larper.keybind`**, ou seja,
> quando **você** digitou o comando ou apertou o atalho. Chamado no carregamento, em `"ready"` ou
> em `"message"` ele dá erro. Isso é de propósito: responder sozinho às mensagens dos outros
> transforma a conta num *self-bot*, o que o Discord proíbe e costuma punir com banimento.
> Para reagir a mensagens, use `larper.notify`.

### `larper.channel()` e `larper.guild()`

O canal aberto (`{ id, name }`) e o servidor dele (`{ id, name }`). `nil` quando não há canal aberto
(tela de amigos) ou, no caso de `guild()`, numa mensagem direta.

### `print(...)`

Vai para o log do app (`[nome.lua] …` no terminal), não para a interface.

## Sandbox e limites

Cada plugin roda num Lua 5.4 separado (um não enxerga o outro), na thread da interface.

- **Bibliotecas**: só `string`, `table`, `math`, `utf8` e as funções básicas, mais `os.time`,
  `os.date`, `os.clock` e `os.difftime`. Não existem `io`, `os.execute`/`os.remove`/`os.getenv`,
  `require`, `package`, `debug`, `coroutine`, `load`, `loadfile`, `dofile`, `collectgarbage` nem
  `string.dump`: um plugin não lê nem grava arquivos, não roda programas e não acessa a rede.
- **Instruções**: cada chamada (carregar o arquivo, um evento, um comando, um atalho) pode rodar
  até ~5 milhões de instruções. Passou disso, o plugin é **parado** e o erro aparece na página
  (um `while true do end` não congela o app). `pcall` não segura esse erro.
- **Memória**: até 8 MB por plugin; passar disso vira um erro `not enough memory` comum.
- **Erros** não derrubam o app: viram um aviso vermelho e ficam escritos na página do plugin,
  com `arquivo:linha`. Depois de 10 erros o plugin é parado. Corrija o arquivo e clique em
  **Recarregar** (ou desligue e ligue).
- Arquivos acima de 256 KB não são carregados; no máximo 64 plugins.
- Sem plugins na pasta, o app não faz trabalho nenhum a mais (nem aloca nada) por mensagem,
  tecla ou quadro.

Os plugins rodam com a sua conta: só use arquivos que você leu e entende.
