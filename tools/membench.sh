#!/usr/bin/env bash
# Mede RAM (PSS) e CPU parado de cada tema e falha se passar do orçamento.
#   tools/membench.sh [orçamento_em_MB]   (padrão: 60)
# No Hyprland a janela abre num workspace escondido; em outros ambientes ela
# aparece por alguns segundos.
set -euo pipefail
cd "$(dirname "$0")/.."
budget="${1:-60}"
zig build -Doptimize=ReleaseFast
bin="$PWD/zig-out/bin/larpercord"
fail=0
printf "%-10s %10s %12s\n" tema "RAM (PSS)" "CPU parado"
for t in classico vidro terminal subsolo orbital editorial bolhas zen papel escritorio; do
    if command -v hyprctl >/dev/null && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        hyprctl dispatch exec "[workspace special:larper silent] $bin --theme $t --no-live" >/dev/null
    else
        "$bin" --theme "$t" --no-live >/dev/null 2>&1 &
    fi
    sleep 4
    pid=$(pgrep -nx larpercord)
    t1=$(awk '{print $14+$15}' "/proc/$pid/stat"); sleep 5; t2=$(awk '{print $14+$15}' "/proc/$pid/stat")
    kb=$(awk '/^Pss:/{print $2}' "/proc/$pid/smaps_rollup")
    kill "$pid"; sleep 0.5
    mb=$(awk -v k="$kb" 'BEGIN{printf "%.1f", k/1024}')
    cpu=$(awk -v d=$((t2 - t1)) 'BEGIN{printf "%.2f", d/5}')
    printf "%-10s %8s MB %11s%%\n" "$t" "$mb" "$cpu"
    if awk -v m="$mb" -v b="$budget" 'BEGIN{exit !(m > b)}'; then fail=1; fi
done
[ "$fail" = 0 ] || { echo "passou do orçamento de ${budget} MB"; exit 1; }
