# Writing themes

**English** · [Português](README.pt-BR.md)

A larperCord theme is a [KDL](https://kdl.dev) file that describes **the whole interface**:
colors, fonts, styles and the layout tree. You can move everything around without writing
a line of code.

Put the file in `~/.config/larpercord/themes/my-theme.kdl` (or in `themes/`, when running
from inside the repository). **When you save, the app reloads right away.** If there's an error, a
notice shows `file:line:column` and the previous theme stays in effect.

Switch themes with `F2`, from the palette (`Ctrl+K` → "theme: …") or in Settings → Appearance.

## Minimal example

```kdl
theme "my-theme" description="Servers at the bottom, chat on top." preview=classic
palette "wal"                      // uses pywal colors (optional)

colors {
    accent "wal:4"
    surface "mix(wal:0, black, 0.2)"
}

layout {
    column {
        row flex=1 {
            channel-list width=240 bg=sidebar
            column flex=1 {
                messages flex=1
                composer height=46 inset-x=16 inset-y=4
            }
        }
        guild-bar height=60 orientation=horizontal
    }
}
```

## Top-level nodes

| Node | What it does |
|---|---|
| `theme "name" description=… author=… preview=…` | metadata. `preview` picks the thumbnail in settings: `classic`, `glass`, `terminal`, `bubbles`, `zen`, `mirror`, `office` |
| `palette "wal"` or `palette "#hex" …` | the 16 base colors (`wal:0` … `wal:15`). Without it, a default palette is used |
| `colors { token "expression" … }` | overrides color tokens (list below) |
| `roles "color" …` | up to 8 role colors (usernames, server icons) |
| `fonts ui="Inter" mono="JetBrains Mono" size=16` | families (resolved by fontconfig) and base size |
| `metrics radius=6` | default rounding of rows and buttons |
| `window transparent=#true` | transparent window background: the compositor applies blur |
| `styles { style "name" … }` | named styles to use with `style=name` |
| `layout { … }` | the interface tree (a single child at the root) |

## Colors

Expressions accepted anywhere a color is asked for:

```
"#df68ad"   "#df68ad80"   "#fff"   "#fff8"
"wal:4"                    palette color
"@surface"                 another token (already defined)
"mix(a, b, 0.3)"           blend
"alpha(a, 0.5)"            transparency
"lighten(a, 0.1)"  "darken(a, 0.2)"
white  black  transparent
```

Tokens: `bg` `rail` `sidebar` `surface` `elevated` `overlay` `text` `muted` `faint` `accent`
`accent-text` `border` `hover` `selected` `online` `idle` `dnd` `danger` `mention` `link`
`code-bg` `bubble-self` `bubble-self-text` `bubble-other` `shadow`.

## Styles

```kdl
styles {
    style "card" bg="@surface" radius=18 border="@border" border-width=1.5 glow="@accent" shadow=16
}
```

`glow` is the border color when the mouse is over it. `shadow` is the shadow size.
For a plain background with no named style, use it directly on the node: `bg=sidebar radius=12`.

## Layout

Containers: `row` (horizontal), `column` (vertical), `stack` (one on top of another).

| Property | Effect |
|---|---|
| `width=` / `height=` | fixed size along the parent's axis |
| `flex=` | weight in the leftover space (default 1) |
| `gap=` `padding=` `padding-x=` `padding-y=` | spacing (containers) |
| `inset-x=` `inset-y=` | inner margin of a component |
| `max-width=` | limits the width and centers |
| `hide-below=` | hides when the window is narrower than this |
| `show=#false` | hides |
| `style=` / `bg=` `radius=` | the node's background |
| `font=mono` / `font=ui` / `font="Liberation Serif"` | the component's font: the mono one, the interface one or **any installed family** |
| `c-<token>=color` | overrides a color token **on this node and its children** (e.g. `c-text="#fff"` on a dark sidebar) |

## Components

| Component | Properties |
|---|---|
| `guild-bar` | `variant=bar\|dock\|list` `icon-style=fill\|soft\|outline` `orientation=vertical\|horizontal` `shape=circle\|squircle\|square\|text` `size=48` `labels=#true` `home=#false` `indicators=#false` |
| `channel-list` | `variant=discord\|tree\|pills` `header=#false` |
| `user-panel` | `variant=discord\|tty` |
| `header` | `variant=discord\|minimal\|tty` `divider=#false` |
| `tabs` | `variant=pills\|underline\|tty` |
| `messages` | `variant=cozy\|irc\|bubbles` `avatar=circle\|squircle\|square\|none` `avatar-size=40` `spacing=16` `font-size=` |
| `composer` | `variant=box\|pill\|prompt` `typing=#false` |
| `member-list` | `variant=discord\|tty` |
| `status-bar` | `variant=pills\|tty\|plain` `items="conn ping ram frame voice spacer theme keys clock"` |
| `label` | `text=` `size=` `weight=regular\|medium\|semibold\|bold` `color=token` `align=left\|center\|right` |
| `logo` | `variant=ascii\|wordmark` `size=` |
| `topbar` | top bar (tabs, search, help) |
| `crt` | `spacing=3` `strength=0.08` |
| `spacer` | empty space |

A name that doesn't exist shows up with a red border and the file line, to make it easy to spot.

## Light and dark

Every theme has both versions. Blocks with `mode=` only apply in one of the modes:

```kdl
colors mode=dark  { bg "#0b0906"; text "#ffcf73" }
colors mode=light { bg "#f4efe2"; text "#2e2412" }
roles mode=light "#7a4a00" "#9c3f10"
```

Without `mode=`, the block applies in both. If the theme doesn't define the light one, it's derived
from the palette (near-white paper, dark ink and a darkened accent). In the layout, `cl-<token>` and
`cd-<token>` override a color in light only or dark only. Users choose in Settings → Appearance
(Dark / Light / Follow system), or on the command line: `--mode light`.

## Theme options

A theme can offer on/off switches, which show up in Settings → Appearance:

```kdl
options {
    option "crt" label="Efeito CRT" description="Linhas de varredura…" default=#true
    option "verde" label="Fósforo verde" default=#false
}
```

Ways to use the options:

| Where | How |
|---|---|
| hide/show a node | `crt when=crt`, `tabs unless=compacto` |
| boolean property | `banner="$banner"`, `typing="$!digitando"` (the `!` inverts) |
| block of colors, roles, styles | `colors mode=dark when=verde { … }` |
| style | `style "card" sheen="$brilho"` |

The choices are saved per theme in `~/.config/larpercord/settings.kdl`.

## Custom colors (without editing the `.kdl`)

In **Settings → Appearance → Theme colors** you can replace any color token
(`bg`, `sidebar`, `text`, `accent`, `link`, `bubble-self`…) and the eight role colors with
a free-form hex. It only applies to the **current theme and the current mode** (dark or light), and it takes
priority over the global "Accent color".

- `#RRGGBB` for an opaque color; `#RRGGBBAA` for a color with transparency.
- Click an item in the grid, paste the hex and press Enter.
- "Clear this color" returns that item to the theme; "Reset theme" erases the theme's choices.
- The choices are kept in `settings.kdl` as `theme-colors "name" mode=dark accent="#…"`,
  so they don't change the theme file.
- Parts that use a fixed `c-…` in the layout (some themes do this to keep contrast) keep
  the file's color; to change those, edit the `.kdl`.

### In both languages

The interface comes in Portuguese and English. For your theme to look right in both, put the English
version alongside: `label-en=` and `description-en=` on options, and `description-en=` on the `theme` node.
Without them, the Portuguese text shows up.

```kdl
theme "my-theme" description="Servidores embaixo." description-en="Servers at the bottom."
options {
    option "crt" label="Efeito CRT" label-en="CRT effect" description="Linhas de varredura" description-en="Scanlines"
}
```

## Exclusive features

| Component / property | What it does | Used in |
|---|---|---|
| `channel-list banner=#true` | colored banner with the server name | classico |
| `style … sheen=#true` | glass reflection at the top of the card | vidro |
| `crt` | scanlines + vignette, on top of everything (use it in a `stack`) | terminal, subsolo |
| `logo variant=ascii\|wordmark` | the app logo in ASCII or as text | terminal, subsolo, escritorio |
| `messages ruled=#true margin-line=#true` | ruled paper and red margin | papel |
| `messages ticks=#true typing-bubble=#true` | "Delivered ✓✓" and a typing bubble | bolhas |
| `autohide=#true` (any node) | the component disappears until the mouse gets close | zen |
| `guild-bar variant=bar orientation=horizontal` | horizontal strip of servers at the bottom, no icon zoom | orbital |
| `topbar` | back/forward between tabs, search and help | escritorio, editorial (optional in orbital) |

## The bundled themes

- [`classico.kdl`](classico.kdl): the familiar layout
- [`vidro.kdl`](vidro.kdl): translucent cards with compositor blur
- [`terminal.kdl`](terminal.kdl): tmux + IRC in amber phosphor
- [`subsolo.kdl`](subsolo.kdl): underground hacking terminal, acid green, ultraviolet and scanlines
- [`orbital.kdl`](orbital.kdl): ship console with numbered systems, a command prompt and a server strip at the bottom
- [`editorial.kdl`](editorial.kdl): printed magazine, serif masthead and an index on the right
- [`bolhas.kdl`](bolhas.kdl): light, with chat bubbles
- [`zen.kdl`](zen.kdl): one central column and nothing else
- [`papel.kdl`](papel.kdl): serif and mirrored
- [`escritorio.kdl`](escritorio.kdl): Slack-style, shows off `c-…` and `variant=list`

The tests (`zig build test`) load every built-in theme and build the layout of each one.
If you send a new theme in a pull request, it's checked automatically.

## Design tips

What separates a good-looking theme from a strange one is almost never the accent color. It's usually:

- **A single concept.** "Notebook", "terminal", "1989 laptop"… and everything follows it: colors,
  font, corners and borders.
- **Surfaces that separate.** Background, panels and elevated elements need clear steps of
  lightness. Purple on purple on purple turns into one blob.
- **Few bright colors.** One accent and, at most, one secondary. Use `roles` with colors from the
  same family so the names don't become a rainbow.
- **One text font**, and at most one for headings (`header … font="Liberation Serif"`).
- **Enough contrast** for `text`, `muted` and `faint` against each panel's background. Use `c-…`
  when part of the layout has a very different background (a dark sidebar in a light theme).
