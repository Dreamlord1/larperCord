# Getting started

larperCord is a native Discord client for Linux, written in Zig. You can run it without an account: `--demo` starts **demo mode**, with fake servers and fake people, and it doesn't connect to anything. With no token configured, the app opens the sign-in screen, which also offers the demo.

> [!WARNING]
> **Third-party clients break Discord's Terms of Service**, and your account can be banned. Use a real account at your own risk, ideally a secondary one. This project has no affiliation with Discord Inc.

## What you need

| | |
|---|---|
| Operating system | Linux. It uses inotify and `/proc`, and it's tested on Arch with Hyprland |
| Compiler | Zig 0.17 |
| Libraries | SDL3, FreeType, fontconfig, libcurl (with WebSocket support, 7.86 or newer), zlib, libwebp, Opus, OpenSSL |
| Recommended fonts | Inter, JetBrains Mono and Noto Color Emoji. fontconfig picks substitutes if one is missing |
| Optional | FFmpeg 7, 8 or 9 (libavformat 61–63) to play video inside the app. Any other version is ignored and videos open in the browser |

There are no prebuilt packages yet, so you build from source.

## Build and run

```bash
# Arch Linux
sudo pacman -S zig sdl3 freetype2 fontconfig curl zlib libwebp opus openssl \
    inter-font ttf-jetbrains-mono noto-fonts-emoji

git clone https://github.com/RshaCuDeVidro/larperCord
cd larperCord

zig build -Doptimize=ReleaseFast
./zig-out/bin/larpercord --demo
```

Everything else is already in the repository: Dear ImGui, Lua, stb_image, libdave, MLSpp and nlohmann/json are copied into `third_party/`, so the build downloads nothing.

## Your first five minutes

1. Press `F2` a few times. Every press swaps the whole theme file.
2. Press `Ctrl+K` and type `theme`, or a channel name. That's the command palette, and almost everything is in it.
3. Press `Ctrl+,` to open settings. Look at Appearance, where each theme has its own options.
4. Right-click a message, a user, a channel and a server. Everything has a menu.
5. Copy a theme and edit it while the app is open:

```bash
mkdir -p ~/.config/larpercord/themes
cp themes/orbital.kdl ~/.config/larpercord/themes/mine.kdl
$EDITOR ~/.config/larpercord/themes/mine.kdl
```

Change the `theme "orbital"` line to `theme "mine"`, pick it with `F2` or in the palette, and every save reloads the window. If you make a mistake, a notice shows `file:line:column` and the previous version stays on screen. [Writing themes](page:themes) has the whole language.

## Next steps

- [Connect your account](page:account), if you accept the risk.
- [Feature tour](page:features), to see what's in there.
- [Shortcuts and CLI](page:shortcuts), for every key and flag.
