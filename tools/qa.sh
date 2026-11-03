#!/usr/bin/env bash
# QA completo: a bateria geral no tema classico e a bateria por tema em
# todos os temas, no escuro e no claro. Não abre janela. Prints em qa-out/.
set -uo pipefail
cd "$(dirname "$0")/.."
zig build || exit 1
rm -rf qa-out && mkdir -p qa-out
bin=./zig-out/bin/larpercord
total_fail=0
run() {
    local label="$1"; shift
    local out; out=$("$@" 2>&1 | grep -v '^info:')
    local line; line=$(echo "$out" | grep 'passaram')
    printf "%-24s %s\n" "$label" "${line%%(*}"
    if ! echo "$line" | grep -q ' 0 falharam'; then
        total_fail=1
        echo "$out" | sed -n '/^Falhas:/,$p' | sed 's/^/    /'
    fi
}
run "geral (classico)" $bin --qa --theme classico
for t in classico vidro terminal bolhas zen papel escritorio; do
    for m in escuro claro; do
        QA_SUITE=tema QA_PREFIX="$t-$m-" run "$t ($m)" $bin --qa --theme "$t" --mode "$m"
    done
done
[ "$total_fail" = 0 ] && echo "tudo passou ✓" || { echo "houve falhas"; exit 1; }
