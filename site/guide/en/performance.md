# Performance

## The numbers

| | RAM (PSS) | Idle CPU | Binary |
|---|---|---|---|
| Vesktop (Electron) | 1,279 MB | 12–47% ¹ | 287 MB |
| **larperCord** ² | **45–50 MB** | **0–0.5%** | **~5 MB** |

¹ Average since launch, measured with `ps`. Arch Linux, Hyprland, GTX 1050 Ti, a 1280×800 window, `ReleaseFast` build.

² Demo data, all 10 themes, real GPU with a hidden window (`LARPER_HIDDEN=1`), which can measure slightly less than a visible window.

Read these with the right caveats:

- **A real account uses more** than demo data. More servers, more members, more images.
- **A good part of PSS isn't the app.** It's the NVIDIA driver and system libraries such as libcurl and OpenSSL. In one measurement across the themes, private anonymous memory was about 22 MB.
- **The binary doesn't include shared libraries**, such as SDL3 and libcurl.
- The Vesktop figures come from a single earlier run on the same machine.

## Measure it yourself

```bash
tools/membench.sh 50
```

For each theme, it opens the app in demo mode, waits, measures idle CPU over 5 seconds, reads PSS from `/proc/<pid>/smaps_rollup`, and fails if any theme goes over the budget in MB.

The Performance page in settings shows live numbers, and `--stats` shows the time to first frame.

## Ten decisions

1. **It sleeps when nothing happens.** The loop waits in `SDL_WaitEvent`. Network, inotify and the clock wake the app through events. No animation, no redraw.
2. **No browser.** Everything is drawn with Dear ImGui's `ImDrawList` on SDL_Renderer.
3. **Fonts are mapped, not copied.** Each font file is one `mmap` used by every weight and family, so only the pages read stay in RAM. Loading 4 weights of Inter plus emoji the naive way cost about 90 MB.
4. **Only the video driver it needs.** On NVIDIA-only machines, glvnd also loaded Mesa and LLVM (about 23 MB) for nothing. The app detects that and avoids it.
5. **Markdown is parsed once**, when the message arrives. The UI only lays out spans, with a height cache per width.
6. **A virtualized list.** Binary search for the first visible item, then draw only the screen.
7. **Memory has ceilings.** 1,500 messages per channel and 3,000 in total, after which the least recently seen conversation is unloaded. Images have a fixed 64 MB budget, and any single download stops at 32 MB.
8. **fontconfig gets freed** after fonts are resolved (`FcFini` and `malloc_trim`).
9. **No blinking cursor.** It would keep the CPU awake for nothing.
10. **Things start when you ask.** The voice thread on the first call and FFmpeg on the first video. Off-screen video is released after 30 seconds, and without plugins there's no extra work per message, key or frame.

## The budget in CI

The test suite covers the pure parts, and a separate job builds the whole app and runs the full QA off-screen. See [Contributing](page:contributing).
