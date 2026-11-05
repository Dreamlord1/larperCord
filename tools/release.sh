#!/usr/bin/env bash
# Publica uma versão: compila Linux e Windows, assina o SHA256SUMS e cria a
# release no GitHub com o trecho do CHANGELOG.md. Rode do main, sem nada pendente.
#   tools/release.sh            (a versão vem de src/core/version.zig)
# A chave fica em ~/.config/larpercord-release/ed25519.seed, fora do repositório.
set -euo pipefail
cd "$(dirname "$0")/.."
ver=$(sed -n 's/^pub const number = "\(.*\)";/\1/p' src/core/version.zig)
key="${LARPER_RELEASE_KEY:-$HOME/.config/larpercord-release/ed25519.seed}"
[ -f "$key" ] || { echo "sem a chave em $key"; exit 1; }
command -v zip >/dev/null || { echo "falta o zip"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "há mudanças sem commit"; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "rode do main"; exit 1; }
grep -q "^## $ver\$" CHANGELOG.md || { echo "CHANGELOG.md sem a seção $ver"; exit 1; }
if gh release view "v$ver" >/dev/null 2>&1; then echo "v$ver já existe"; exit 1; fi

tools/windows_deps.sh
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# Sem -Dcpu=baseline o binário só rodaria em processadores iguais a este.
zig build -Dcpu=baseline -p "$out/linux"
cp "$out/linux/bin/larpercord" "$out/larpercord-linux-x86_64"
zig build -Dtarget=x86_64-windows-gnu -p "$out/win"
cp "$out/win/bin/larpercord.exe" "$out/larpercord-windows-x86_64.exe"
cp "$out"/win/bin/*.dll "$out/"
# O .exe não abre sem as DLLs: quem baixa pelo site recebe tudo junto.
mkdir "$out/larperCord"
cp "$out/win/bin/larpercord.exe" "$out"/win/bin/*.dll "$out/larperCord/"
(cd "$out" && zip -qr larpercord-windows-x86_64.zip larperCord)
assets=(larpercord-linux-x86_64 larpercord-windows-x86_64.zip larpercord-windows-x86_64.exe SDL3.dll libcurl-x64.dll libcrypto-3-x64.dll)
(cd "$out" && sha256sum "${assets[@]}" > SHA256SUMS)
zig run tools/release_sign.zig -- sign "$key" "$out/SHA256SUMS"
awk -v v="## $ver" '$0==v{on=1;next} /^## /{on=0} on' CHANGELOG.md > "$out/notes.md"
cd "$out"
gh release create "v$ver" --title "larperCord $ver" --notes-file notes.md "${assets[@]}" SHA256SUMS SHA256SUMS.sig
