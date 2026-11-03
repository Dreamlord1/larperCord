# larperCord

Cliente alternativo de Discord, nativo e leve. Feito em Zig com SDL3, Dear ImGui e FreeType.

Por enquanto é só o **protótipo visual**: usa dados falsos e ainda não tem rede.

## Rodar

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/larpercord
```

Variáveis de ambiente:

| Variável | O que faz |
|---|---|
| `LARPER_RENDERER=vulkan` | troca o backend do SDL (`opengl` é o padrão e o mais leve aqui) |
| `LARPER_SHOT=print.png` | salva um print depois de alguns quadros e fecha |
| `LARPER_EGL_ALL=1` | desliga o atalho que força o EGL da NVIDIA |

## Medir a RAM

```bash
awk '/^Pss:/{printf "%.1f MB\n", $2/1024}' /proc/$(pgrep -x larpercord)/smaps_rollup
```

Na máquina de desenvolvimento (GTX 1050 Ti, Hyprland, 1280×800): **~40 MB** e CPU em 0% quando parado.

## Estrutura

```
src/main.zig    janela, laço de eventos (dorme quando nada acontece)
src/ui.zig      barra de servidores, canais, chat, membros
src/text.zig    fontes e texto rico (negrito, `código`, @menção, emoji)
src/theme.zig   paleta lida do pywal (~/.cache/wal/colors)
src/anim.zig    animações com easing por id
src/icons.zig   ícones vetoriais
src/fake.zig    dados falsos do protótipo
third_party/    Dear ImGui 1.93.0 + dear_bindings 0.27
```

## Modificações em third_party

O `third_party/imgui/misc/freetype/imgui_freetype.cpp` foi alterado para aceitar fontes só de
bitmap (CBDT, como a Noto Color Emoji): ele escolhe o maior tamanho disponível da fonte e
reduz cada glyph para o tamanho pedido. Os trechos alterados estão marcados com `[larperCord]`.
