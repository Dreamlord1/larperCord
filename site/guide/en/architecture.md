# Architecture

About 34,000 lines of Zig on top of a thin C layer. The rule that shapes everything: **the UI never changes data directly**.

## Data flow

```text
UI → Action → app → Command → gateway → Event → Store → UI
```

The UI only reads the Store and requests actions. The app turns them into commands for the gateway, which runs on its own thread, and events come back through a queue into the Store. That's why swapping the demo gateway for the real one doesn't touch the UI.

## Source tree

```text
src/
  core/       pure data, no window: types (snowflakes), Store, markdown, events,
              inbox, saved messages, filters, search queries, cache format
  net/        the real gateway (Discord) and the demo one, queues, voice,
              settings protobuf, message cache, proxy, media URLs
  theme/      KDL parser, colors, theme loader, layout engine, manager + inotify
  ui/         components, rich text, palette, settings, animations, images, video
  plugins/    the Lua engine and its host
  platform/   window, renderer, waking the loop, FFmpeg loading. The only
              place that knows about SDL's windowing
themes/       the built-in themes (also compiled into the binary)
third_party/  vendored code: Dear ImGui, dear_bindings, Lua, stb_image, libdave,
              MLSpp, nlohmann/json
tools/        QA, memory benchmark, screenshots, logo and site generators
```

## Threads

| Thread | When it exists | Job |
|---|---|---|
| UI | Always | The main loop, sleeping in `SDL_WaitEvent` when nothing happens. Lua plugins run here too |
| Gateway | With a token | WebSocket with heartbeat, RESUME, zlib-stream and reconnects, plus REST, one request at a time |
| Demo gateway | Without a token | Fake servers, people and messages |
| Media | Always, mostly asleep | Downloads and decodes images at low priority, at most 2 decodes at a time |
| Theme watcher | Unless disabled | Waits on inotify for changes to theme files and pywal colors |
| Video | While playing | One thread downloads, another decodes into a 3-frame ring |
| Voice | During a call | Voice gateway, UDP, Opus and DAVE |

## Talking to Discord

The gateway uses WebSocket (`v=10`, JSON, `zlib-stream`) with heartbeat, session RESUME and reconnects. It connects the way the web client does. REST handles history, sending, editing, deleting, reactions and "typing", one request at a time and respecting rate limits.

## The rendering

Everything is drawn with Dear ImGui's `ImDrawList` over SDL_Renderer, and FreeType renders the text. ImGui is an immediate-mode library, so its usual cost is redrawing all the time. Here, the loop only draws when something changes:

- **Input, network, inotify and the clock** wake the loop through events.
- **Animations** ask for frames only while they're running.
- **Lists** use binary search to find the first visible item and draw only what's on screen.
- **Markdown** is parsed once, when the message arrives, with a height cache per width.

## Themes as data

A theme is parsed into colors, styles and a tree of nodes. The layout engine computes rectangles from `row`, `column`, `stack`, `flex` and sizes, then a table in `src/ui/root.zig` maps component names to draw functions. A component it doesn't know appears with a red border and the file's line number.

[Writing themes](page:themes) documents the language, and the [playground on the home page](home:playground) lets you try it in your browser.

## How it stays light

See [Performance](page:performance).
