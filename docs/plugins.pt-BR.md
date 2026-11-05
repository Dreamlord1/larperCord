# Plugins em Lua

[English](plugins.md) · **Português**

Plugins são scripts pequenos que somam funções ao app, sem recompilar: painéis, entradas no botão
direito, comandos, lembretes, notas embaixo das mensagens. Todo arquivo `.lua` em

```
~/.config/larpercord/plugins/          ($XDG_CONFIG_HOME/larpercord/plugins, se existir)
```

é um plugin. Abra **Configurações → Plugins** (`Ctrl+,`) para ver o que cada um é, o que pede e o
erro que deu, ligar ou desligar (a escolha fica em `~/.config/larpercord/plugins.kdl`), aprovar os
hosts com que ele quer falar, abrir o painel dele e **Recarregar** depois de editar um arquivo.

## Os plugins que vêm com o app

**Configurações → Plugins → Instalar os incluídos** copia os que faltam para a sua pasta. Nunca
sobrescreve um arquivo que você editou e nunca apaga nada.

| Plugin | O que faz |
|---|---|
| [`translate.lua`](plugins/translate.lua) | Botão direito numa mensagem, ou o 🌐 na barra dela, para ver a tradução embaixo. "Traduzir para…" escolhe outro idioma só para aquela mensagem, o cartão define o idioma de destino e o de origem, e `/tr es olá` põe uma tradução na caixa de mensagem. Desligado até você aprovar o host: veja [HTTP](#larperhttp) |
| [`reminders.lua`](plugins/reminders.lua) | `/remind 10m ligar de volta`, `/remind amanhã 9h pagar a conta`, `/remind todo dia 8:30 reunião`, ou "Lembrar" numa mensagem. Avisa na hora certa, mesmo depois de reabrir o app. O que já avisou pode voltar em 10 minutos |
| [`highlights.lua`](plugins/highlights.lua) | Palavras para acompanhar em todos os canais: um aviso, um número no painel para o que você não viu, e um histórico que leva à mensagem. Dá para silenciar um canal |
| [`snippets.lua`](plugins/snippets.lua) | Textos guardados que vão para a caixa de mensagem enquanto você digita (`;nome`), com um clique ou `/snip nome`. Nunca envia nada |
| [`cleanlinks.lua`](plugins/cleanlinks.lua) | Tira o rastreio dos links que você envia (`utm_*`, `fbclid`, o `si` do YouTube e do Spotify…). O app aplica as regras ao enviar: o plugin não vê o que você escreve |
| [`timestamps.lua`](plugins/timestamps.lua) | `/ts amanhã 15h` ou `/ts sexta 20h` põe na caixa de mensagem um horário que cada pessoa vê no próprio fuso |
| [`links.lua`](plugins/links.lua) | Todos os links e arquivos das mensagens carregadas no canal aberto: busque, abra, copie, vá até a mensagem. Só olha com o painel aberto, e não guarda nada no disco |

Nenhum deles guarda o texto de uma mensagem depois que ela é apagada ou editada: o plugin fica sabendo
e joga fora o texto velho. Destaques nunca grava no disco o texto de outra pessoa.

**Versão nova de um incluído:** quando o app traz um `@version` maior de um arquivo que você tem, o
cartão mostra **Atualizar para vX**. Só troca com esse clique, e o seu arquivo fica ao lado como
`nome.lua.bak` (depois `.bak2`, e assim por diante): nada é sobrescrito.

**Não vêm mais com o app:** favoritos e o filtro de palavras viraram as Mensagens salvas e os Alertas e
filtros do próprio app; estatísticas e algumas demonstrações (calc, shrug, dado…) saíram. Quem tem
continua usando, e **Arquivar em antigos/** move para `plugins/antigos/`, que não é carregada. Nada é
apagado.

## Como os plugins rodam

O código dos plugins roda numa thread só deles, nunca na da interface: um plugin lento ou travado
não engasga o app. A interface e essa thread só conversam por duas filas.

- Cada plugin tem o próprio Lua 5.4: um não enxerga o outro.
- **Sem plugin ligado, a thread não existe** e nenhum estado de Lua é criado. Com plugins ligados e
  nada acontecendo, a thread dorme: sem varredura, sem temporizador, sem quadros. Um plugin com
  temporizador pendente acorda ela na hora certa (e uma vez por minuto se o prazo estiver longe, porque
  o computador pode dormir no meio).
- Os plugins ligam quando você entra na conta, e ligam de novo ao trocar de conta: cada conta tem os
  seus dados.
- Tudo o que um plugin manda para a tela é dado (uma árvore, uma regra, uma nota, uma lista de
  sugestões). O app desenha e aplica sozinho, sem chamar o Lua por mensagem, por quadro nem por tecla.
- Não existe evento de presença, de digitação nem de voz: disparam tanto que escutá-los seria um custo
  constante, mesmo com o plugin sem fazer nada.
- Se a fila atrasar, um plugin que demora em cada mensagem perde mensagens em vez de segurar os
  outros. O cartão dele diz quantas.

## Um exemplo

```lua
-- @name Shrug
-- @name:pt Dar de ombros
-- @description /shrug sends a shrug.
-- @description:pt /shrug manda um dar de ombros.
-- @version 1.0.0
-- @capabilities send

larper.command("/shrug", function(args)
  local text = "¯\\_(ツ)_/¯"
  if args ~= "" then text = args .. " " .. text end
  larper.send(larper.channel(), text)
end)
```

Escreva `/shrug sei lá` na caixa de mensagem e o canal recebe `sei lá ¯\_(ツ)_/¯`. O `/shrug` em si
nunca vai para o Discord.

## O cabeçalho

Os comentários no começo do arquivo dizem o que o plugin é. O app lê sem rodar nada, então a página
de configurações mostra tudo isso mesmo com o plugin desligado.

| Linha | Para que serve |
|---|---|
| `-- @name Bookmarks` | O nome (e `-- @name:pt Favoritos` em português) |
| `-- @description …` | Uma ou duas frases (e `-- @description:pt …`) |
| `-- @version 1.0.0` | Aparece ao lado do nome |
| `-- @capabilities menu, panel, storage` | O que ele pede. Aparece no cartão, e é só isso que ele pode usar |
| `-- @hosts api.exemplo.com` | Os hosts de [`larper.http`](#larperhttp), só o nome. Sem endereço IP, porta nem domínio do Discord |

| Capacidade | Dá acesso a |
|---|---|
| `messages` | `larper.on("message")`, `larper.on("edit")`, `larper.on("delete")`, `larper.messages` |
| `send` | `larper.send` |
| `notify` | `larper.notify` |
| `storage` | `larper.storage` |
| `timers` | `larper.after`, `larper.every` |
| `panel` | `larper.panel` |
| `menu` | `larper.menu` |
| `decorate` | `larper.decorate`, `larper.undecorate`, `larper.rules`, `larper.on("dismiss")` |
| `composer` | `larper.insert` |
| `http` | `larper.http` (pede `@hosts`) |
| `lsp` | `larper.lsp` |
| `settings` | `larper.settings` |
| `completions` | `larper.completions` |
| `rewrite` | `larper.rewrite` (o cartão diz "Altera o que você envia") |
| `links` | `larper.open` (o cartão diz "Abre links") |

Comandos, atalhos, `larper.channel`, `larper.guild`, `larper.jump`, `larper.copy`, `larper.tr` e
`larper.json` não pedem capacidade nenhuma. Chamar o que o cabeçalho não pede dá um erro que diz o que acrescentar.

**Arquivos sem cabeçalho** continuam funcionando: são plugins de "API antiga", com `messages`, `send`,
`notify` e `lsp`. Para usar o que veio depois, acrescente um cabeçalho. Um cabeçalho com erro (uma
capacidade desconhecida, um host inválido) impede o plugin de ligar, e o cartão diz por quê. Um plugin
que lê mensagens e também consegue mandar algo para fora (`messages` com `http` ou `links`) ganha uma
linha de aviso no cartão, além das etiquetas.

## Limites

É isso que deixa rodar scripts de outras pessoas ao lado da sua conta.

- **Um plugin nunca vê o seu token nem o seu e-mail.**
- **Enviar uma mensagem só funciona direto de um gesto naquele plugin**: um comando, atalho, botão do
  painel (ou Enter num campo dele) ou entrada de menu. Não ao carregar, num evento, num temporizador
  nem na resposta de um pedido HTTP. Responder sozinho transformaria a conta num *self-bot*, o que o
  Discord proíbe e costuma punir com banimento. Não existe resposta automática, reação automática nem
  nada que escreva na conta em segundo plano.
- `larper.insert`, `larper.jump`, `larper.copy`, `larper.open` e `larper.panel.open` também pedem um
  gesto: um plugin em segundo plano não escreve na sua caixa de mensagem nem leva você para outro
  lugar. A única exceção: a resposta de um pedido HTTP feito num gesto pode chamar `larper.insert`.
  Enviar, ela continua sem poder.
- **Sem arquivos, programas nem sockets.** Só `string`, `table`, `math`, `utf8` e as funções básicas,
  mais `os.time`, `os.date`, `os.clock` e `os.difftime`. Não existe `io`,
  `os.execute`/`os.remove`/`os.getenv`, `require`, `package`, `debug`, `coroutine`, `load`, `loadfile`,
  `dofile`, `collectgarbage` nem `string.dump`.
- **Instruções**: cada chamada (carregar o arquivo, um evento, um comando…) pode rodar até ~5 milhões
  de instruções. Passou disso, o plugin é **parado**, com o erro no cartão. `pcall` não segura esse erro.
- **Memória**: até 8 MB por plugin; passar disso é um erro comum de `not enough memory`.
- **Erros** não derrubam o app: viram um aviso vermelho e ficam escritos no cartão do plugin, com
  `arquivo:linha`. Um erro ao carregar o arquivo, ou 10 erros depois, param o plugin. Corrija o arquivo
  e clique em **Recarregar** (ou desligue e ligue).
- Arquivos acima de 256 KB não carregam; no máximo 64 plugins. Se os eventos chegarem mais rápido do
  que um plugin dá conta, as mensagens em excesso se perdem; o que você faz nele, nunca.

Plugins rodam com a sua conta: só use arquivos que você leu e entendeu.

## API

Tudo fica na tabela global `larper`. IDs do Discord são textos (`"1234567890"`).

### `larper.on(evento, função)`

| evento | quando | argumento |
|---|---|---|
| `"message"` | chega uma mensagem nova em qualquer canal (inclusive sua) | `msg` |
| `"edit"` | alguém editou uma mensagem | `msg`, com o texto novo |
| `"delete"` | uma mensagem foi apagada | `{ id, channel }` (IDs) |
| `"dismiss"` | você fechou a nota deste plugin com o × dela | `{ id }` |
| `"ready"` | o app conectou (ou o plugin ligou com o app já conectado) | nenhum |
| `"channel"` | você abriu outro canal | `{ id, name }`, ou `nil` |
| `"lang"` | o idioma do app mudou: desenhe o seu painel de novo | nenhum |
| `"panel"` | o seu painel abriu ou fechou na tela | `true` ou `false` |

`msg` tem:

| campo | exemplo |
|---|---|
| `msg.content` | `"bom dia"` |
| `msg.author` | `{ id = "1001", name = "ana" }` |
| `msg.channel` | `{ id = "5000", name = "geral" }` |
| `msg.guild` | `{ id = "500", name = "Servidor" }`, ou `nil` em mensagens diretas |
| `msg.mine` | `true` se foi você que mandou |
| `msg.ignored` | `true` se você ignora quem escreveu |
| `msg.id` | `"1350000000000000000"` |
| `msg.time` | segundos desde 1970 |
| `msg.attachments` | quantos |
| `msg.files` | só em `larper.messages({ files = true })`: uma lista de `{ name, url, size }` |

O histórico carregado ao abrir um canal não dispara `"message"`, só o que chega ao vivo. Mensagens de
sistema (fulano entrou, fixou…) também não. Um plugin nunca recebe o que foi apagado nem o texto de uma
mensagem de antes de ela ser editada, nem com o registro de mensagens ligado.

```lua
larper.on("message", function(msg)
  if not msg.mine and msg.content:lower():find("pizza", 1, true) then
    larper.notify(msg.author.name .. " falou de pizza em #" .. msg.channel.name)
  end
end)
```

### `larper.command("/nome", função(args))`

Um comando local: quando você envia uma mensagem que começa com `/nome`, a função roda com o resto do
texto (`args`, sem espaços nas pontas, `""` se não tem nada) e **nada vai para o Discord**. O nome é `/`
seguido de letras, números, `_` ou `-` (até 32). Se dois plugins registram o mesmo nome, vale o primeiro
na ordem dos arquivos. Um `/qualquer` que nenhum plugin ligado conhece vai como texto normal.

### `larper.keybind("ctrl+shift+x", função)`

Um atalho de teclado. Modificadores: `ctrl`, `shift`, `alt`, `super`; teclas: `a`–`z`, `0`–`9`,
`f1`–`f24`, `enter`, `space`, `tab`, `backspace`, `delete`, `insert`, `home`, `end`, `pageup`,
`pagedown`, `up`, `down`, `left`, `right`, `,` `.` `/` `;` `-` `=`. Letras e números pedem `ctrl`, `alt`
ou `super` (senão disparariam enquanto você digita); as teclas F podem ir sozinhas. O atalho funciona
fora das configurações e da paleta de comandos, inclusive com a caixa de texto em foco. Os atalhos do
app (`Ctrl+K`, `Ctrl+W`…) continuam funcionando junto: escolha outra combinação.

### `larper.notify(texto, [opções])`

Mostra um aviso no topo da janela. Com a janela fora de foco (e "Notificações na área de trabalho"
ligado), sai também uma notificação do sistema, menos no modo foco. Com `{ desktop = true }` a
notificação do sistema sai mesmo com a janela em foco ou no modo foco, para o que a pessoa pediu
explicitamente, como um lembrete. No máximo 20 a cada 10 segundos e 6 notificações do sistema por minuto
por plugin (20 por minuto somando todos); o resto se perde em silêncio.

### `larper.send(canal, texto)`

Envia uma mensagem de verdade, como se você tivesse digitado. `canal` pode ser `nil` (o canal aberto),
uma tabela com `id` (como `larper.channel()` ou `msg.channel`) ou o ID em texto. `texto` tem de 1 a 2000
bytes. No máximo 5 por gesto. Veja [Limites](#limites).

### `larper.channel()` e `larper.guild()`

O canal aberto (`{ id, name }`) e o servidor dele (`{ id, name }`). `nil` sem canal aberto (tela de
amigos) ou, em `guild()`, numa mensagem direta.

### `larper.messages([opções], função(lista))`

As mensagens carregadas no canal aberto, da mais antiga para a mais nova, numa cópia. Opções: `channel`
(um ID), `limit` (200 por padrão, até 500) e `files` (`true` também traz `msg.files`: só quem pede paga
por isso). A resposta chega em `função`, depois. Devolve `false`, sem nunca chamar a função, se pedir de
novo em menos de meio segundo.

### `larper.jump(canal, mensagem)`

Abre o canal e vai até a mensagem, buscando se preciso. Pede um gesto.

### `larper.insert(texto)`

Põe texto na caixa de mensagem. Nunca envia. Pede um gesto, ou a resposta de um pedido HTTP feito num.

### `larper.copy(texto)` e `larper.open(url)`

`larper.copy` põe texto na área de transferência. `larper.open` abre um endereço `http://` ou `https://`
no navegador, e pede a capacidade `links`: um endereço pode levar dados, então o cartão avisa quando o
plugin também lê mensagens. Os dois pedem um gesto.

### `larper.completions(gatilho, lista)`

Sugestões na caixa de mensagem enquanto alguém digita o gatilho no começo de uma palavra:

```lua
larper.completions(";", { { name = "oi", text = "Olá, tudo bem?", hint = "saudação" } })
```

Digitar `;o` mostra a lista, e escolher põe `text` na caixa, no lugar de `;o`. Nunca envia. A lista fica
com o app, então a busca roda a cada tecla sem chamar o seu plugin; chame de novo quando ela mudar. O
gatilho é um destes: `;` `!` `$` `%` `&` `+` `=` `?` `^`. Até 256 sugestões e 256 KB por plugin.

### `larper.rewrite(lista)`

Regras fixas para o texto que a pessoa envia:

```lua
larper.rewrite({
  { strip_params = { "utm_*", "fbclid" } },                 -- em links, em qualquer lugar
  { strip_params = { "si" }, host = "youtu.be" },           -- só ali e nos subdomínios
  { replace_host = "antigo.exemplo.com", with = "novo.exemplo.com" },
  { word = "vc", with = "você" },                           -- palavra inteira, sem ligar para maiúsculas; sem menção nem link
})
```

O app aplica ao enviar, depois de resolver as menções. O seu plugin não vê o que foi escrito e nada roda
enquanto se digita. Bloco de código, menção e emoji ficam como estão. Se o resultado não couber numa
mensagem, o texto vai como foi escrito. Cada chamada troca as regras do plugin; até 256, contando cada
parâmetro. Não mexe no que `larper.send` envia, nem em edições.

### `larper.lang()` e `larper.tr(pt, en)`

`larper.lang()` é `"pt"` ou `"en"`, e `larper.tr("olá", "hello")` é o texto no idioma da interface. Os
plugins devem usar isso em todo texto, e desenhar de novo em `larper.on("lang", …)`.

### `larper.after(segundos, função)`, `larper.every(segundos, função)`, `larper.cancel(id)`

Temporizadores que rodam com o plugin ligado e morrem com ele. Os dois retornam um ID para
`larper.cancel`. `every` tem mínimo de 1 segundo. Um plugin pode ter até 64. Para sobreviver a reabrir
o app, guarde a hora em `larper.storage` e crie o temporizador de novo ao carregar, como `reminders.lua` faz.

### `larper.storage`

Dados que ficam de uma vez para outra, separados por plugin e por conta, neste computador
(`~/.config/larpercord/plugin-data/`). Até 1 MB por plugin.

| Função | O que faz |
|---|---|
| `larper.storage.get(chave)` | O valor, ou `nil`. É uma cópia: mudar não grava |
| `larper.storage.set(chave, valor)` | Guarda texto, número, booleano ou tabela (lista, ou com chaves de texto). `nil` apaga. Dá erro se não couber, e o valor antigo fica lá |
| `larper.storage.delete(chave)` | Apaga |
| `larper.storage.keys()` | A lista de chaves |
| `larper.storage.clear()` | Apaga tudo |

Vai para o disco logo depois da mudança, fora da thread da interface, e quando o plugin para. Um arquivo
que não dá para ler fica guardado ao lado como `.bad`, e o plugin começa vazio, com o erro no cartão.

### `larper.panel`

Um painel que o app desenha numa lateral que a pessoa encaixa de qualquer lado e ajusta a largura. Chega-se
nele pelo botão no cabeçalho do canal, pela paleta de comandos (`Painel: nome`) ou por **Abrir painel** no
cartão do plugin. Você descreve com dados, e publica de novo sempre que algo muda.

```lua
local function desenha()
  larper.panel.set({
    title = larper.tr("Meu painel", "My panel"),
    { type = "heading", text = "Título" },
    { type = "text", text = "Texto que quebra a linha", style = "muted" },
    { type = "input", key = "busca", placeholder = "Buscar", value = busca,
      on_change = function(v) busca = v; desenha() end,
      on_submit = function(v) end },
    { type = "row",
      { type = "button", label = "Guardar", style = "accent", on_click = function() end },
      { type = "button", label = "Apagar", style = "danger", on_click = function() end },
    },
    { type = "bar", label = "ana", value = 12, max = 30, text = "12" },
    { type = "select", key = "tipo", label = "Mostrar", value = tipo,
      options = { { value = "tudo", label = "Tudo" }, { value = "novo", label = "Novos" } },
      on_change = function(v) tipo = v; draw() end },
    { type = "toggle", key = "som", label = "Som", hint = "Texto opcional embaixo", value = som,
      on_change = function(on) som = on end },
    { type = "separator" },
    { type = "list", empty = "Nada por aqui.", items = {
      { title = "Título", subtitle = "Até 4 linhas", meta = "12:30",
        on_click = function() end,
        actions = { { label = "Tirar", style = "danger", on_click = function() end } } },
    } },
  })
end
```

| Tipo | Campos |
|---|---|
| `text` | `text`, `style` (`muted`, `accent`, `danger`) |
| `heading` | `text` |
| `separator` | nenhum |
| `row` | botões na parte de lista, quebrando a linha quando não cabem |
| `button` | `label`, `style`, `on_click` |
| `input` | `key` (obrigatório), `placeholder`, `value`, `on_change(texto)`, `on_submit(texto)` (Enter), `clear` (esvazia no Enter) |
| `bar` | `label`, `value`, `max`, `text`, `style` |
| `select` | `key` (obrigatório), `label`, `value`, `options` (`{ value, label }`), `on_change(valor)` |
| `toggle` | `key` (obrigatório), `label`, `hint`, `value`, `on_change(true ou false)` |
| `list` | `items`, `empty` (o texto quando não tem nenhum) |
| item da lista | `title`, `subtitle`, `meta`, `on_click`, `actions` (botões) |

Qualquer um aceita `key`. Enquanto alguém digita num campo, publicar não sobrescreve o que está lá; com
o foco em outro lugar, vale `value`. `larper.panel.open()` (pede um gesto) e `larper.panel.close()`
mostram e escondem. Até 4000 itens e 1 MB de texto. Um clique numa opção
ou num interruptor conta como gesto. Um `badge` ao lado de `title` (um texto curto, como `"3"`) aparece
na etiqueta do painel e como um ponto no botão do cabeçalho do canal, que então abre esse painel primeiro.
Publique sem ele para limpar.

### `larper.settings.set(lista)`

Opções no cartão do plugin em **Configurações → Plugins**, com os mesmos tipos de um painel, em geral
`select` e `toggle`. Aparecem enquanto o plugin está ligado. Quem guarda o valor é o seu plugin, com
`larper.storage`, e ele publica de novo em `"lang"`:

```lua
-- @capabilities settings, storage
local alvo = larper.storage.get("alvo") or "auto"
local function opcoes()
  larper.settings.set({
    { type = "select", key = "alvo", label = larper.tr("Traduzir para", "Translate to"), value = alvo,
      options = { { value = "auto", label = "Idioma do app" }, { value = "es", label = "Espanhol" } },
      on_change = function(v) alvo = v; larper.storage.set("alvo", v) end },
  })
end
larper.on("lang", opcoes)
opcoes()
```

### `larper.menu(onde, rótulo, função, [opções])`

Uma entrada no menu do botão direito. `onde` é `"message"` (a função recebe `msg`, como em `larper.on`,
da mensagem clicada) ou `"user"` (recebe `{ id, name }`). `rótulo` é um texto ou `{ pt = "…", en = "…" }`.
Até 4 por plugin. Opções:

| Opção | O que faz |
|---|---|
| `choices` | Uma segunda lista, até 16 `{ value, pt, en }`. Clicar na entrada abre, e o `value` escolhido é o segundo argumento da função |
| `toolbar` | Um emoji: a entrada também vira um botão na barra da mensagem sob o mouse, com o rótulo como dica. Só em `"message"`, e no máximo 3 somando todos os plugins |

```lua
larper.menu("message", { pt = "Traduzir para…", en = "Translate to…" }, function(msg, idioma)
  traduzir(msg, idioma)
end, { choices = { { value = "es", pt = "Espanhol", en = "Spanish" } } })
```

### `larper.decorate(mensagem, opções)` e `larper.undecorate(mensagem)`

Marca uma mensagem, só na sua tela. `mensagem` é um ID ou uma `msg`.

| Opção | O que faz |
|---|---|
| `badge` | Um selo pequeno embaixo da mensagem |
| `note` | Uma linha de texto embaixo da mensagem, até 2000 bytes, com um × para dispensar |
| `collapse` | `true` recolhe numa linha, com "mostrar" |
| `label` | O texto dessa linha |

Até 4096 por plugin. Quando a mensagem é apagada, o que estava nela vai junto. Quando a pessoa fecha
uma nota com o ×, `larper.on("dismiss")` avisa.

### `larper.rules(lista)`

A mesma coisa como regras que o app aplica sozinho, inclusive nas mensagens que chegarem depois, sem
chamar o seu plugin:

```lua
larper.rules({
  { word = "spoiler", collapse = true, label = "Recolhida pelo meu filtro" },
  { user = "1234567890", badge = "!" },
})
```

`word` pega palavras inteiras, sem diferenciar maiúsculas. Cada chamada troca as regras do plugin. Até
256. As suas próprias mensagens nunca são afetadas.

### `larper.http`

Pedidos para fora, fora da thread da interface. É a única rede que um plugin tem.

```lua
-- @capabilities http
-- @hosts api.exemplo.com
larper.http.get("https://api.exemplo.com/x?q=" .. larper.urlencode(texto), function(res)
  if res.ok then local dados = larper.json.decode(res.body) end
end)
```

`larper.http.get(url, [opções], função)` e `larper.http.post(url, opções, função)`. Opções: `body` (até
64 KB) e `headers`. A função recebe `{ ok, status, body, error }`. `error` é `"not_approved"`,
`"rate_limited"`, `"too_big"` ou `"network"`.

- **Só HTTPS**, e só para um host que está em `@hosts` e que **você aprovou no cartão do plugin**,
  separado por plugin e por host. Até lá nada sai, e o plugin recebe `not_approved`.
  `larper.http.allowed(host)` diz se está aprovado.
- Uma URL com usuário, porta ou caracteres sem codificar dá erro. Um host fora de `@hosts` também. Os
  domínios do próprio Discord nem podem ser declarados.
- Redirecionamento não é seguido: o 3xx volta para o plugin, então não leva a um host que você não aprovou.
- O app não manda cookies, token nem cabeçalhos do Discord. Um plugin só escolhe `Accept`,
  `Accept-Language` e `Content-Type`; o resto é jogado fora.
- Limites: respostas de até 1 MB, 20 segundos por pedido, 3 ao mesmo tempo e 30 por minuto, por plugin.
- Respeita o seu proxy, se você usa um.

### `larper.json.encode(valor)`, `larper.json.decode(texto)` e `larper.urlencode(texto)`

`decode` retorna o valor, ou `nil` e uma mensagem de erro. `encode` aceita o que `larper.storage.set` aceita.

### `larper.lsp(linguagem, argv)`

Propõe um servidor de linguagem para os blocos de código na caixa de mensagem
([erros no código](lsp.pt-BR.md)): `linguagem` é a etiqueta do bloco ou uma chave de linguagem daquela
página (`"zig"`, `"python"`, `"haskell"`), e `argv` é o programa e os argumentos, sem shell no meio.

```lua
larper.lsp("haskell", {"haskell-language-server-wrapper", "--lsp"})
```

Isso não roda nada. A proposta aparece em Configurações → Erros no código, desligada, com o comando
inteiro. Só roda depois que você ligar, para aquele plugin, linguagem e comando exatos; mudar o comando
desliga de novo. O plugin nunca vê o que você digita nem o que o servidor responde. Um plugin pode propor
até 8 servidores; chamar de novo para a mesma linguagem troca a proposta.

### `print(...)`

Vai para o log do app (`[nome.lua] …` no terminal), não para a interface.
