# Lua plugins

**English** · [Português](plugins.pt-BR.md)

Plugins are small scripts that add features to the app with no recompiling: panels, right-click
entries, commands, reminders, notes under messages. Every `.lua` file in

```
~/.config/larpercord/plugins/          ($XDG_CONFIG_HOME/larpercord/plugins, if set)
```

is a plugin. Open **Settings → Plugins** (`Ctrl+,`) to see what each one is, what it asks for and
any error it hit, turn it on or off (the choice is kept in `~/.config/larpercord/plugins.kdl`),
approve the hosts it wants to talk to, open its panel and **Reload** after editing a file.

## The plugins that come with the app

**Settings → Plugins → Install bundled plugins** copies the missing ones to your folder. It never
overwrites a file you've edited and never removes anything.

| Plugin | What it does |
|---|---|
| [`bookmarks.lua`](plugins/bookmarks.lua) | Right-click a message to save it. The panel lists them, with search, and takes you back to the message. Stored on this computer |
| [`reminders.lua`](plugins/reminders.lua) | `/remind 10m call back`, or "Remind me" on a message. Notifies you at the right time, also after a restart |
| [`highlights.lua`](plugins/highlights.lua) | Words to watch across all channels: a notification, and a panel with the history that takes you to the message |
| [`filter.lua`](plugins/filter.lua) | Collapses messages by word or by person, with a "show" button. Only on your screen |
| [`snippets.lua`](plugins/snippets.lua) | Saved texts that go into the message box with one click or `/snip name`. It never sends anything |
| [`translate.lua`](plugins/translate.lua) | Right-click a message to see the translation under it. Off until you approve the host: see [HTTP](#larperhttp) |
| [`stats.lua`](plugins/stats.lua) | Top talkers and when people talk, from the messages already loaded in the channel |

None of them keeps the text of a message after it's deleted: the plugin hears about the deletion
and drops it. Highlights never writes other people's text to disk.

## How plugins run

Plugin code runs on a thread of its own, never on the interface thread, so a slow or stuck plugin
can't make the app stutter. The interface and that thread only talk through two queues.

- Each plugin has its own Lua 5.4 state: one can't see another.
- **With no plugin on, the thread doesn't exist** and no Lua state is created. With plugins on and
  nothing happening, the thread is asleep: no polling, no timers, no frames. A plugin with a pending
  timer wakes it when that's due (and once a minute if the timer is far away, because a computer can
  sleep in the meantime).
- Plugins start when you're logged in, and start again when you switch accounts: each account has
  its own data.
- Everything a plugin sends to the screen is data (a tree, a rule, a note). The app draws it on its
  own, without calling Lua per message or per frame.

## An example

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

Type `/shrug no idea` in the message box and the channel receives `no idea ¯\_(ツ)_/¯`. The
`/shrug` itself never goes to Discord.

## The manifest

The comments at the top of the file say what the plugin is. The app reads them without running
anything, so the settings page shows them even for a plugin that's off.

| Line | What it's for |
|---|---|
| `-- @name Bookmarks` | The name (and `-- @name:pt Favoritos` in Portuguese) |
| `-- @description …` | One or two sentences (and `-- @description:pt …`) |
| `-- @version 1.0.0` | Shown next to the name |
| `-- @capabilities menu, panel, storage` | What it asks for. Shown on its card, and the only things it can use |
| `-- @hosts api.example.com` | The hosts for [`larper.http`](#larperhttp), just the name. No IP address, port or Discord domain |

| Capability | Gives access to |
|---|---|
| `messages` | `larper.on("message")`, `larper.on("delete")`, `larper.messages` |
| `send` | `larper.send` |
| `notify` | `larper.notify` |
| `storage` | `larper.storage` |
| `timers` | `larper.after`, `larper.every` |
| `panel` | `larper.panel` |
| `menu` | `larper.menu` |
| `decorate` | `larper.decorate`, `larper.undecorate`, `larper.rules` |
| `composer` | `larper.insert` |
| `http` | `larper.http` (needs `@hosts`) |
| `lsp` | `larper.lsp` |

Commands, keybinds, `larper.channel`, `larper.guild`, `larper.jump`, `larper.tr` and `larper.json`
don't need any capability. Calling something the manifest doesn't ask for raises an error that says
what to add.

**Files with no manifest** keep working: they are "old API" plugins, with `messages`, `send`,
`notify` and `lsp`. To use anything newer, add a manifest. A manifest with a mistake (an unknown
capability, a bad host) stops the plugin from starting, and the card says why.

## Limits

These are what make it safe to run other people's scripts next to your account.

- **A plugin never sees your token or your email.**
- **Sending a message only works directly from a gesture on that plugin**: its command, keybind,
  panel button (or Enter in one of its inputs) or menu entry. Not at load time, in an event, in a
  timer or in the answer to an HTTP request. Replying on its own would turn the account into a
  *self-bot*, which Discord forbids and usually punishes with a ban. There are no auto-replies,
  auto-reactions or anything else that writes to the account in the background.
- `larper.insert`, `larper.jump` and `larper.panel.open` also need a gesture: a background plugin
  can't type into your message box or move you around.
- **No files, programs or raw sockets.** Only `string`, `table`, `math`, `utf8` and the basic
  functions, plus `os.time`, `os.date`, `os.clock` and `os.difftime`. There is no `io`,
  `os.execute`/`os.remove`/`os.getenv`, `require`, `package`, `debug`, `coroutine`, `load`,
  `loadfile`, `dofile`, `collectgarbage` or `string.dump`.
- **Instructions**: each call (loading the file, an event, a command…) can run up to ~5 million
  instructions. Go past that and the plugin is **stopped**, with the error on its card. `pcall` can't
  catch this error.
- **Memory**: up to 8 MB per plugin; going over is a regular `not enough memory` error.
- **Errors** don't bring the app down: they become a red notice and are written on the plugin's card,
  with `file:line`. An error while loading the file, or 10 errors later on, stops the plugin. Fix the
  file and click **Reload** (or turn it off and on).
- Files over 256 KB aren't loaded; at most 64 plugins. If events arrive faster than a plugin handles
  them, the excess messages are dropped; what you do on it never is.

Plugins run with your account: only use files you've read and understand.

## API

Everything lives in the global table `larper`. Discord IDs are strings (`"1234567890"`).

### `larper.on(event, function)`

| event | when | argument |
|---|---|---|
| `"message"` | a new message arrives in any channel (including your own) | `msg` |
| `"delete"` | a message was deleted | `{ id, channel }` (IDs) |
| `"ready"` | the app connected (or the plugin started while the app was already connected) | none |
| `"channel"` | you opened another channel | `{ id, name }`, or `nil` |
| `"lang"` | the app's language changed: draw your panel again | none |
| `"panel"` | your panel opened or closed on the screen | `true` or `false` |

`msg` has:

| field | example |
|---|---|
| `msg.content` | `"good morning"` |
| `msg.author` | `{ id = "1001", name = "ana" }` |
| `msg.channel` | `{ id = "5000", name = "general" }` |
| `msg.guild` | `{ id = "500", name = "Server" }`, or `nil` in direct messages |
| `msg.mine` | `true` if you sent it |
| `msg.ignored` | `true` if you ignore whoever wrote it |
| `msg.id` | `"1350000000000000000"` |
| `msg.time` | seconds since 1970 |
| `msg.attachments` | how many |

The history loaded when you open a channel doesn't fire `"message"`, only what arrives live.
System messages (someone joined, pinned…) don't either. A plugin never gets what was deleted, or a
message's text from before it was edited, not even with the message log turned on.

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

### `larper.notify(text, [options])`

Shows a notice at the top of the window. With the window unfocused (and "Desktop notifications"
on), a system notification goes out too, except in focus mode. With `{ desktop = true }` the system
notification goes out even with the window focused or in focus mode, for something the person
explicitly asked for, like a reminder. At most 20 per 10 seconds and 6 system notifications a minute;
the rest are dropped silently.

### `larper.send(channel, text)`

Sends a real message, as if you had typed it. `channel` can be `nil` (the open channel), a table
with an `id` (like `larper.channel()` or `msg.channel`) or the ID as a string.
`text` is 1 to 2000 bytes. At most 5 per gesture. See [Limits](#limits).

### `larper.channel()` and `larper.guild()`

The open channel (`{ id, name }`) and its server (`{ id, name }`). `nil` when no channel is open
(friends screen) or, for `guild()`, in a direct message.

### `larper.messages([options], function(list))`

The messages loaded in the open channel, oldest first, as a copy. Options: `channel` (an ID) and
`limit` (200 by default, up to 500). The answer arrives in `function`, later. It returns `false`, and
never calls the function, if you ask again within half a second.

### `larper.jump(channel, message)`

Opens the channel and goes to the message, fetching it if needed. Needs a gesture.

### `larper.insert(text)`

Puts text in the message box. It never sends. Needs a gesture.

### `larper.lang()` and `larper.tr(pt, en)`

`larper.lang()` is `"pt"` or `"en"`, and `larper.tr("olá", "hello")` is the text in the interface's
language. Plugins should use it for all their text, and draw again on `larper.on("lang", …)`.

### `larper.after(seconds, function)`, `larper.every(seconds, function)`, `larper.cancel(id)`

Timers that run while the plugin is on, and die with it. Both return an ID for `larper.cancel`.
`every` has a minimum of 1 second. A plugin can have up to 64. To survive a restart, keep the time in
`larper.storage` and start the timer again when the plugin loads, as `reminders.lua` does.

### `larper.storage`

Data that stays between restarts, separate for each plugin and account, on this computer
(`~/.config/larpercord/plugin-data/`). Up to 1 MB per plugin.

| Function | What it does |
|---|---|
| `larper.storage.get(key)` | The value, or `nil`. It's a copy: changing it doesn't save |
| `larper.storage.set(key, value)` | Saves a string, number, boolean or table (a list, or with string keys). `nil` deletes. Raises an error if it doesn't fit, leaving the old value there |
| `larper.storage.delete(key)` | Deletes |
| `larper.storage.keys()` | The list of keys |
| `larper.storage.clear()` | Deletes everything |

It goes to disk shortly after the change, off the interface thread, and when the plugin stops. A file
that can't be read is kept next to it as `.bad`, and the plugin starts empty with the error on its card.

### `larper.panel`

A panel the app draws in a side panel the person can dock on either side and resize. Reach it with the
button in the channel header, the command palette (`Panel: name`) or **Open panel** on the plugin's
card. You describe it as data; publish again whenever something changes.

```lua
local function draw()
  larper.panel.set({
    title = larper.tr("Meu painel", "My panel"),
    { type = "heading", text = "Heading" },
    { type = "text", text = "Text that wraps", style = "muted" },
    { type = "input", key = "search", placeholder = "Search", value = query,
      on_change = function(v) query = v; draw() end,
      on_submit = function(v) end },
    { type = "row",
      { type = "button", label = "Save", style = "accent", on_click = function() end },
      { type = "button", label = "Delete", style = "danger", on_click = function() end },
    },
    { type = "bar", label = "ana", value = 12, max = 30, text = "12" },
    { type = "separator" },
    { type = "list", empty = "Nothing here yet.", items = {
      { title = "Title", subtitle = "Up to 4 lines", meta = "12:30",
        on_click = function() end,
        actions = { { label = "Remove", style = "danger", on_click = function() end } } },
    } },
  })
end
```

| Type | Fields |
|---|---|
| `text` | `text`, `style` (`muted`, `accent`, `danger`) |
| `heading` | `text` |
| `separator` | none |
| `row` | buttons in its list part, wrapping when they don't fit |
| `button` | `label`, `style`, `on_click` |
| `input` | `key` (required), `placeholder`, `value`, `on_change(text)`, `on_submit(text)` (Enter), `clear` (empties on Enter) |
| `bar` | `label`, `value`, `max`, `text`, `style` |
| `list` | `items`, `empty` (the text when there are none) |
| list item | `title`, `subtitle`, `meta`, `on_click`, `actions` (buttons) |

Any of them takes a `key`. While someone is typing in an input, publishing doesn't overwrite what's
there; with the focus elsewhere, `value` wins. `larper.panel.open()` (needs a gesture) and
`larper.panel.close()` show and hide it. Up to 4000 items and 1 MB of text.

### `larper.menu(where, label, function)`

An entry on the right-click menu. `where` is `"message"` (the function receives `msg`, as in
`larper.on`, for the message you clicked) or `"user"` (it receives `{ id, name }`). `label` is a string
or `{ pt = "…", en = "…" }`. Up to 4 per plugin.

### `larper.decorate(message, options)` and `larper.undecorate(message)`

Marks a message, only on your screen. `message` is an ID or a `msg`.

| Option | What it does |
|---|---|
| `badge` | A small label under the message |
| `note` | A line of text under the message, up to 2000 bytes, with an × to dismiss |
| `collapse` | `true` collapses it to one line, with "show" |
| `label` | The text of that line |

Up to 4096 per plugin. When a message is deleted, what was on it goes too.

### `larper.rules(list)`

The same thing as rules the app applies on its own, including to messages that arrive later, without
calling your plugin:

```lua
larper.rules({
  { word = "spoiler", collapse = true, label = "Collapsed by my filter" },
  { user = "1234567890", badge = "!" },
})
```

`word` matches whole words, ignoring case. Each call replaces the plugin's rules. Up to 256. Your own
messages are never affected.

### `larper.http`

Requests to the outside world, off the interface thread. This is the only network a plugin has.

```lua
-- @capabilities http
-- @hosts api.example.com
larper.http.get("https://api.example.com/x?q=" .. larper.urlencode(text), function(res)
  if res.ok then local data = larper.json.decode(res.body) end
end)
```

`larper.http.get(url, [options], function)` and `larper.http.post(url, options, function)`. Options:
`body` (up to 64 KB) and `headers`. The function receives `{ ok, status, body, error }`. `error` is
`"not_approved"`, `"rate_limited"`, `"too_big"` or `"network"`.

- **HTTPS only**, and only to a host in `@hosts` that **you approved on the plugin's card**, separately
  for each plugin and host. Until then nothing goes out, and the plugin gets `not_approved`.
  `larper.http.allowed(host)` says whether it's approved.
- A URL with a user, a port or characters that aren't encoded raises an error. So does a host that's
  not in `@hosts`. Discord's own domains can't be declared at all.
- Redirects aren't followed: the 3xx comes back to the plugin, so it can't lead to a host you didn't approve.
- The app sends no cookies, no token and no Discord headers. A plugin can only set `Accept`,
  `Accept-Language` and `Content-Type`; anything else is dropped.
- Limits: answers up to 1 MB, 20 seconds per request, 3 at a time and 30 a minute per plugin.
- It respects your proxy, if you have one.

### `larper.json.encode(value)`, `larper.json.decode(text)` and `larper.urlencode(text)`

`decode` returns the value, or `nil` and an error message. `encode` takes what `larper.storage.set`
takes.

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
