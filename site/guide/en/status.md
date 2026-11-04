# Status and roadmap

larperCord is a young project: version 0.4.0, with its first commit on November 2, 2026. It's usable, but it isn't complete.

## What works today

| Area | State | Detail |
|---|---|---|
| Messages, DMs, reactions, replies | **works** | Send, edit, delete, history, mentions |
| Images | **works** | Avatars and attachments, with a fixed-size cache |
| Video in chat | **works** | Attachments and direct links. Needs the system's FFmpeg |
| Inbox, saved messages, offline search | **works** | All local, can be turned off and erased |
| Multiple accounts, proxy, Lua plugins | **works** | |
| Themes | **works** | 10 built-in, each light and dark, reload on save |
| Voice | partial | E2EE (DAVE), mixer and mute work. Default device only, no push-to-talk, no noise suppression, and no automated call test |
| Permissions | partial | Channels without access get a padlock and voice without permission is blocked. Those channels still appear, and the composer, reactions and member list don't check permissions |
| Notifications | partial | Through `notify-send`. Clicking doesn't open the channel, and there's no system tray |
| Accessibility | partial | Font scale, reduced motion, palette and vim navigation. No visible focus and no high contrast |
| First run | partial | Sign-in screen and demo mode, no introduction to the app |
| Platforms | partial | Linux only (uses inotify and `/proc`). Tested on Arch with Hyprland |
| Custom emoji | missing | `<:name:id>` shows up as text |
| Joining a server by invite | missing | |
| Threads and forums | missing | The "started a thread" notice appears, but you can't open it |
| Screen sharing and camera | missing | |

## Roadmap

**Done**

- [x] Real gateway (WebSocket, heartbeat, reconnects) and REST respecting rate limits
- [x] Session RESUME and zlib-stream
- [x] Presences, members and server and channel events
- [x] Images: avatars and attachments with a fixed-size cache
- [x] Voice: voice gateway, UDP, Opus and DAVE/MLS

**To make the app complete**

- [ ] Real permissions: hide what you can't see, disable composer and reactions, filter members
- [ ] Join a server by invite
- [ ] Custom emoji in messages
- [ ] Native D-Bus notifications with "open conversation", and a system tray
- [ ] Threads and forums
- [ ] Voice: device picker, push-to-talk, noise suppression and an automated call test
- [ ] Accessibility and first run: visible focus, high contrast, a welcome screen

**Themes**

- [ ] Engine with assets: gradients, grain, tracking, shapes and rules, effects, overlay and z-order, per-theme fonts and images
- [ ] Gallery and editor: real thumbnails, import and export `.kdl`, a component inspector
- [ ] Theme components written in Lua (sandboxed)

**Later**

- [ ] A software backend (`wl_shm`, no GPU), to get to about 15–20 MB
