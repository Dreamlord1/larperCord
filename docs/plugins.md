# Lua plugins

**English** · [Português](plugins.pt-BR.md)

Plugins are small scripts that react to what happens in the app and add commands and keybinds,
with no recompiling. Every `.lua` file in

```
~/.config/larpercord/plugins/          ($XDG_CONFIG_HOME/larpercord/plugins, if set)
```

is a plugin. Open **Settings → Plugins** (`Ctrl+,`) to see the list, turn each one on or off
(the choice is kept in `~/.config/larpercord/plugins.kdl`), see the error from any that broke, and
**Reload** after editing a file.

## An example

```lua
-- ~/.config/larpercord/plugins/shrug.lua
larper.command("/shrug", function(args)
  local text = "¯\\_(ツ)_/¯"
  if args ~= "" then text = args .. " " .. text end
  larper.send(larper.channel(), text)
end)
```

Type `/shrug no idea` in the message box and the channel receives `no idea ¯\_(ツ)_/¯`. The
`/shrug` itself never goes to Discord.

The full examples are in [`docs/plugins/`](plugins/):

| Plugin | What it does |
|---|---|
| [`shrug.lua`](plugins/shrug.lua) | `/shrug`: the command above |
| [`alerta.lua`](plugins/alerta.lua) | notifies you when someone writes a word from your list |
| [`dado.lua`](plugins/dado.lua) | `/dado 2d20+3`, `/moeda` and `/escolhe pizza, sushi`, with the result in the channel |
| [`zoeira.lua`](plugins/zoeira.lua) | `/mock`, `/vapor`, `/palmas`, `/contrario` and `/spoiler` rewrite the text |
| [`calc.lua`](plugins/calc.lua) | `/calc 2+3*4` answers only you; `/conta` sends it to the channel. A hand-written parser, a good model for your own syntax |
| [`relogio.lua`](plugins/relogio.lua) | `/hora tokyo`, `/horario lisboa` and a `/cronometro` (also on `Ctrl+Alt+T`) |
| [`resumo.lua`](plugins/resumo.lua) | `/resumo` (or `Ctrl+Alt+R`): how many messages, who talked most and where, since the app opened |

To install: **Settings → Plugins → Install examples** copies the missing ones to your folder
(without overwriting what you've edited). Or by hand:
`mkdir -p ~/.config/larpercord/plugins && cp docs/plugins/*.lua ~/.config/larpercord/plugins/`
and **Reload**.

## API

Everything lives in the global table `larper`. Discord IDs are strings (`"1234567890"`).

### `larper.on(event, function)`

| event | when | argument |
|---|---|---|
| `"message"` | a new message arrives in any channel (including your own) | `msg` |
| `"ready"` | the app connected (or the plugin was loaded or turned on while the app was already connected) | none |

`msg` has:

| field | example |
|---|---|
| `msg.content` | `"good morning"` |
| `msg.author` | `{ id = "1001", name = "ana" }` |
| `msg.channel` | `{ id = "5000", name = "general" }` |
| `msg.guild` | `{ id = "500", name = "Server" }`, or `nil` in direct messages |
| `msg.mine` | `true` if you sent it |
| `msg.id` | `"1350000000000000000"` |

The history loaded when you open a channel doesn't fire `"message"`, only what arrives live.
System messages (someone joined, pinned…) don't either.

```lua
larper.on("message", function(msg)
  if not msg.mine and msg.content:lower():find("pizza", 1, true) then
    larper.notify(msg.author.name .. " talked about pizza in #" .. msg.channel.name)
  end
end)
```

### `larper.command("/name", function(args))`

A local command: when you send a message that starts with `/name`, the function runs with the
rest of the text (`args`, trimmed at both ends, `""` if there's nothing) and **nothing goes to
Discord**. The name is `/` followed by letters, numbers, `_` or `-` (up to 32). If two plugins
register the same name, the first one in file name order wins. A `/something` that no enabled
plugin knows is sent as normal text.

### `larper.keybind("ctrl+shift+x", function)`

A keyboard shortcut. Modifiers: `ctrl`, `shift`, `alt`, `super`; keys: `a`–`z`, `0`–`9`,
`f1`–`f24`, `enter`, `space`, `tab`, `backspace`, `delete`, `insert`, `home`, `end`, `pageup`,
`pagedown`, `up`, `down`, `left`, `right`, `,` `.` `/` `;` `-` `=`. Letters and numbers need
`ctrl`, `alt` or `super` (otherwise they'd fire while you type); F keys can go alone.
The shortcut works outside settings and the command palette, including with the text box focused.
The app's own shortcuts (`Ctrl+K`, `Ctrl+W`…) keep working alongside it: pick another combination.

### `larper.notify(text)`

Shows a notice at the top of the window. With the window unfocused (and "Desktop notifications"
on), a system notification goes out too.

### `larper.send(channel, text)`

Sends a real message, as if you had typed it. `channel` can be `nil` (the open channel), a table
with an `id` (like `larper.channel()` or `msg.channel`) or the ID as a string.
`text` is 1 to 2000 bytes. At most 5 per command or keybind.

> [!IMPORTANT]
> **`larper.send` only works inside a `larper.command` or `larper.keybind`**, that is, when
> **you** typed the command or pressed the shortcut. Called at load time, in `"ready"` or in
> `"message"`, it raises an error. This is on purpose: replying on its own to other people's
> messages turns the account into a *self-bot*, which Discord forbids and usually punishes with a ban.
> To react to messages, use `larper.notify`.

### `larper.channel()` and `larper.guild()`

The open channel (`{ id, name }`) and its server (`{ id, name }`). `nil` when no channel is open
(friends screen) or, for `guild()`, in a direct message.

### `larper.lsp(lang, argv)`

Proposes a language server for code blocks in the message box
([code diagnostics](lsp.md)): `lang` is the block tag or a language key from that page (`"zig"`,
`"python"`, `"haskell"`), and `argv` is the program and its arguments, with no shell involved.

```lua
larper.lsp("haskell", {"haskell-language-server-wrapper", "--lsp"})
```

This does not run anything. The proposal appears under Settings → Code diagnostics, off, with the
full command. It only runs after you turn it on, for that plugin, language and exact command;
changing the command turns it off again. The plugin never sees what you type or what the server
answers. A plugin can propose up to 8 servers; calling this again for the same language replaces
the proposal.

### `print(...)`

Goes to the app's log (`[name.lua] …` in the terminal), not to the interface.

## Sandbox and limits

Each plugin runs in its own Lua 5.4 (one can't see another), on the interface thread.

- **Libraries**: only `string`, `table`, `math`, `utf8` and the basic functions, plus `os.time`,
  `os.date`, `os.clock` and `os.difftime`. There is no `io`, `os.execute`/`os.remove`/`os.getenv`,
  `require`, `package`, `debug`, `coroutine`, `load`, `loadfile`, `dofile`, `collectgarbage` or
  `string.dump`: a plugin can't read or write files, run programs or access the network. The one
  way to get a program started is proposing it with `larper.lsp`, which needs your approval.
- **Instructions**: each call (loading the file, an event, a command, a keybind) can run
  up to ~5 million instructions. Go past that and the plugin is **stopped** and the error shows on
  its page (a `while true do end` doesn't freeze the app). `pcall` can't catch this error.
- **Memory**: up to 8 MB per plugin; going over becomes a regular `not enough memory` error.
- **Errors** don't bring the app down: they become a red notice and are written on the plugin's
  page, with `file:line`. After 10 errors the plugin is stopped. Fix the file and click
  **Reload** (or turn it off and on).
- Files over 256 KB aren't loaded; at most 64 plugins.
- With no plugins in the folder, the app does no extra work (and allocates nothing) per message,
  key or frame.

Plugins run with your account: only use files you've read and understand.
