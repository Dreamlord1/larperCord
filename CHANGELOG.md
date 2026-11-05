# What changed in each version

## 0.6.0

**Plugins**
- Translate has options now: target and source language on its card in Settings → Plugins, and "Translate to…" on the right-click menu for one message. A 🌐 on the message toolbar, and `/tr es hello` puts a translation in the message box.
- Scam guard marks in red the classic Discord scams in other people's messages: addresses that imitate Discord or Steam, fake free Nitro with a link, shortened links with bait. It runs on your computer, with no network, and official addresses are never marked.
- CVE radar finds `CVE-2021-44228` in messages and shows the severity, the CVSS score and a summary under it, from the official record. Each number is asked once, and only after you approve the host.
- GitHub cards put the title, the state and the stars under `owner/repo#123` and GitHub links.
- What did I miss sums up the unread messages in a channel: how many from each person, mentions of you, unanswered questions, links and files, with a click to each one.
- Also new: Clean links removes tracking from the links you send, and Links and files lists what was shared in the channel.
- Reminders understand times and dates (`/remind tomorrow 9am`, `/remind every day 8:30`), have a second list on the right-click menu, and what already fired can come back in 10 minutes.
- Highlights shows how many you haven't seen, can mute a channel, follows edits, and can use desktop notifications.
- Bookmarks, the word filter, snippets, timestamps, stats and the demo plugins no longer come with the app: the first two became built-in features. If you have them they keep working, and a button archives them to `plugins/antigos/`. Nothing is deleted.
- A bundled plugin with a newer version shows an update button on its card, and keeps your file as `.bak`.
- New for plugin authors: options on the card (`larper.settings`, `select`, `toggle`), second lists and toolbar buttons on menus, suggestions in the message box (`larper.completions`), rules for what you send (`larper.rewrite`), `larper.copy`, `larper.open`, a number on the panel tab, red notes, the `edit`, `dismiss` and `hosts` events, a `contains` filter that keeps messages away from Lua, and attachments, replies, mentions and the read position in `larper.messages`.
- A plugin that falls behind loses messages instead of holding up the others, and its card says so. Each plugin has its own limit of desktop notifications, so a noisy one doesn't eat a reminder's.
- The card warns about a plugin that reads messages and can also send something out.
- Closing a translation with its × no longer makes the next "Translate" do nothing.

**Messages**
- `<t:…>` times appear as a date or "in 2 hours", in your time zone, instead of the raw code.
- Over a link, the mouse cursor turns into a hand. Text selection was overriding it.
- Mark as read and mark as unread always reach Discord now. While invisible they stayed on your computer only and came back the next time you connected. Your status no longer stops read confirmations; an unfocused window still doesn't confirm on its own.

**Lighter**
- A frame that comes out the same as the last one isn't drawn again, so network events that change nothing on screen cost less.
- Moving the mouse with no button pressed asks for fewer frames.
- After a minute in the tray or minimized, images leave memory, except small ones that were on screen.
- Settings → Performance shows where the memory goes: images, messages, people, servers, fonts, driver and libraries.

**Accounts**
- The sign-in screen lists every saved account as a button, however you got there, with a warning to use a secondary account before you paste a token.
- When Discord refuses a token, the app forgets it instead of trying it again every time it opens. If the session ends with the app open, it goes back to the sign-in screen.

**Install**
- The Linux installer names its shortcut after the window's app ID, so taskbars that look up the icon that way can find it. Running it again replaces the old shortcut.

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
- When the network stalls, the voice fades out instead of cutting off mid-word, and comes back without a pop.
- A pause from someone's noise gate is no longer treated as a bad network, which kept the audio delay low.
- Noise suppression uses less CPU in the published builds: it picks the faster path for your processor when it runs.
- People no longer cut out for a moment when someone joins or leaves the call.

**Tray**
- Closing and reopening no longer stacks up tray icons. On Linux the icon lives in a small separate process that only exists while the window is hidden, so GTK stays out of the app.

**Layout**
- Drag the edge of the channel list, the member list or the panes of a split view to resize them. A double-click goes back to the theme's width, and your choice is saved and follows you between themes.
- A narrow conversation keeps working: the search box steps aside before the buttons do.

**Messages**
- A BOT tag next to the name of bots and webhooks, with a check mark for verified bots, in messages, the member list, DMs and profiles.
- Webhook messages keep the name and picture each one was sent with.
- Bot messages in the newer component format, which used to appear blank. Forwarded messages and polls appear as cards.
- Text in embeds can be selected and copied.
- Discord markdown: headings, small text, quotes, lists and `[text](url)` links. Line numbers in code blocks.
- Selecting text inside a code block is visible now.
- Esc cancels editing a message.
- Right-clicking or middle-clicking a button no longer also triggers its normal click. In the message toolbar, for example, it used to add the reaction.
- Optional code diagnostics while typing a code block, from a language server you choose.

**Servers and groups**
- Edit a server (name, description, icon, banner) or a group DM (name, icon).
- Delete threads.
- Server banners at the top of the channel list and on invite cards.
- Click a server banner to see it in full, and the same for a profile banner. Server and user menus can open the icon or picture too.
- Friends, group and pin icons redrawn.

**Plugins**
- Plugins now run on a thread of their own: a slow or stuck one can't make the interface stutter, and it's stopped with the error on its card. With no plugin on, the thread doesn't exist and no Lua is loaded.
- New plugins that come with the app: bookmarks, reminders, highlights, local filter, snippets, translate and channel stats. Settings → Plugins installs them, without touching your files.
- Settings → Plugins shows a card for each plugin, from a manifest at the top of the file: name, description, version, what it asks for, errors and a way to open its panel, even when it's off.
- What plugins can do now: panels in a side panel you dock on either side, right-click entries on messages and people, badges, notes and collapsing with "show" under messages, their own storage, timers, desktop notifications, loaded messages, jumping to a message and inserting text in the message box.
- Optional HTTPS for plugins, only to hosts you approve one by one, with no cookies, token or Discord headers.
- Files in the plugin folder from before keep working, and the examples that came with the old versions aren't removed.

**Lighter**
- Smaller executable, faster opening and less memory.

## 0.4.0

First public version: real Discord connection, voice with end-to-end encryption, threads and forums, read state, search, Lua plugins and 11 themes.
