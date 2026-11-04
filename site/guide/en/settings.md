# Settings and files

Open settings with `Ctrl+,`. Changes apply right away and are saved in `~/.config/larpercord/settings.kdl`.

## The pages

| Page | What's there |
|---|---|
| **My Account** | Account details and log out |
| **Privacy** | Typing indicator, Tenor and Giphy animation, streamer mode, message log, keep messages on disk, clear cache, and the network proxy |
| **Alerts & Filters** | Alert words, word filter, ignored people and focus mode |
| **Appearance** | Mode (dark, light, follow the system), theme with thumbnails and its options, font scale, compact mode, avatars, 24-hour clock, status ring, accent color, corners, custom theme colors, member list and status bar |
| **Accessibility** | Reduce motion, role colors, underline links |
| **Chat** | Autoplay GIFs, images from links, data saver, always show spoilers, markdown preview |
| **Notifications** | Desktop notifications and taskbar flashing |
| **Keybinds** | The shortcut list and vim navigation |
| **Language** | Follow the system, Português (Brasil) or English (US) |
| **Advanced** | Developer mode (message IDs, "Copy ID") and reload themes on save |
| **Performance** | RAM, CPU per frame, idle CPU and messages per channel |
| **Plugins** | The list of plugins, on/off, errors and Reload |
| **About** | Version and what it's built with |

## Privacy choices worth knowing

| Option | Default | Effect |
|---|---|---|
| Send typing indicator | on | Others see "typing…" while you write |
| Animate Tenor and Giphy GIFs | off | Downloads from their site, which sees your IP. When off, you get a still preview through Discord |
| Streamer mode | off | Hides your email and username in settings |
| Message log | off | Deleted messages stay visible, marked, and edits keep the original. Local only |
| Keep messages on disk | on | Chats open instantly and `Ctrl+F` works offline. Only your user can read the files |

## Files on disk

`$XDG_CONFIG_HOME` and `$XDG_CACHE_HOME` replace `~/.config` and `~/.cache` when set.

| Path | What it is |
|---|---|
| `~/.config/larpercord/settings.kdl` | Settings, including per-theme options and colors |
| `~/.config/larpercord/themes/*.kdl` | Your themes |
| `~/.config/larpercord/plugins/*.lua` | Your plugins |
| `~/.config/larpercord/plugins.kdl` | Which plugins are on or off |
| `~/.config/larpercord/drafts.kdl` | Unsent drafts per channel (`chmod 600`) |
| `~/.config/larpercord/saved-<account>.json` | Saved messages and notes |
| `~/.config/larpercord/accounts` | Saved accounts: ID, name and avatar only |
| `~/.config/larpercord/tokens/<ID>` | Remembered tokens when there's no keyring (`chmod 600`) |
| `~/.config/larpercord/token` | Optional token file (`chmod 600`) |
| `~/.cache/larpercord/messages` | Message cache: folders 700, files 600, 200 messages per channel, 50 MB cap |
| `~/.cache/wal/colors` | Read only: pywal's palette, for themes that use it |

To go back to defaults, close the app and delete `~/.config/larpercord/settings.kdl`.
