# What changed in each version

## 0.5.0

**Windows**
- larperCord now runs on Windows 10 and 11, built from the same code.
- Tokens stay in Windows Credential Manager.

**Updates**
- Checks for a new version when opening or from Settings → Updates.
- One button downloads, installs and restarts. Updates are signed, and a version without the right signature isn't installed.
- Restart button in Settings, and this page.

**Voice**
- Microphone noise suppression with RNNoise, on by default and switchable mid-call. It doesn't run with the push-to-talk key released.
- Less stutter and no more clicks when packets are lost or arrive out of order; the audio buffer grows when the network hiccups.
- People no longer cut out for a moment when someone joins or leaves the call.

**Messages**
- Bot messages in the newer component format, which used to appear blank. Forwarded messages and polls appear as cards.
- Text in embeds can be selected and copied.
- Discord markdown: headings, small text, quotes, lists and `[text](url)` links. Line numbers in code blocks.
- Selecting text inside a code block is visible now.
- Esc cancels editing a message.
- Optional code diagnostics while typing a code block, from a language server you choose.

**Servers and groups**
- Edit a server (name, description, icon, banner) or a group DM (name, icon).
- Delete threads.
- Server banners at the top of the channel list and on invite cards.

**Lighter**
- Smaller executable, faster opening and less memory.

**Plugins**
- Plugins now run on a thread of their own: a slow or stuck one can't make the interface stutter, and it's stopped with the error on its card. With no plugin on, the thread doesn't exist and no Lua is loaded.
- New plugins that come with the app: bookmarks, reminders, highlights, local filter, snippets, translate and channel stats. Settings → Plugins installs them, without touching your files.
- Settings → Plugins shows a card for each plugin, from a manifest at the top of the file: name, description, version, what it asks for, errors and a way to open its panel, even when it's off.
- What plugins can do now: panels in a side panel you dock on either side, right-click entries on messages and people, badges, notes and collapsing with "show" under messages, their own storage, timers, desktop notifications, loaded messages, jumping to a message and inserting text in the message box.
- Optional HTTPS for plugins, only to hosts you approve one by one, with no cookies, token or Discord headers.
- Files in the plugin folder from before keep working, and the examples that came with the old versions aren't removed.

## 0.4.0

First public version: real Discord connection, voice with end-to-end encryption, threads and forums, read state, search, Lua plugins and 11 themes.
