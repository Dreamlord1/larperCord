#!/bin/sh
# Installs larperCord into ~/.local (no sudo) from the latest published version.
#   curl -fsSL https://raw.githubusercontent.com/RshaCuDeVidro/larperCord/main/install.sh | sh
#   sh install.sh --uninstall
set -eu
repo="RshaCuDeVidro/larperCord"
bin_dir="${HOME}/.local/bin"
app_dir="${HOME}/.local/share/applications"
icon_dir="${HOME}/.local/share/icons/hicolor/128x128/apps"

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$bin_dir/larpercord" "$bin_dir/larpercord.old" "$app_dir/larpercord.desktop" "$icon_dir/larpercord.png"
    echo "larperCord removed. Your settings are still in ~/.config/larpercord."
    exit 0
fi

[ "$(uname -s)" = "Linux" ] || { echo "This script is for Linux. On Windows, use install.ps1."; exit 1; }
[ "$(uname -m)" = "x86_64" ] || { echo "Only x86_64 builds are published. On other architectures, build from source (see the README)."; exit 1; }
for tool in curl sha256sum; do
    command -v "$tool" >/dev/null || { echo "Missing command: $tool"; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
base="https://github.com/$repo/releases/latest/download"
echo "Downloading the latest version..."
curl -fsSL --proto '=https' -o "$tmp/larpercord-linux-x86_64" "$base/larpercord-linux-x86_64"
curl -fsSL --proto '=https' -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
(cd "$tmp" && grep ' larpercord-linux-x86_64$' SHA256SUMS | sha256sum -c --quiet -) || { echo "The download does not match SHA256SUMS. Nothing was installed."; exit 1; }

mkdir -p "$bin_dir" "$app_dir" "$icon_dir"
install -m 755 "$tmp/larpercord-linux-x86_64" "$bin_dir/larpercord"
curl -fsSL --proto '=https' -o "$icon_dir/larpercord.png" "https://raw.githubusercontent.com/$repo/main/docs/assets/icon-180.png" || true
cat > "$app_dir/larpercord.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=larperCord
Comment=Native Discord client
Exec=$bin_dir/larpercord
Icon=larpercord
Terminal=false
Categories=Network;InstantMessaging;
DESK

# Libraries come from the system: report what is missing and how to get it.
missing="$(ldd "$bin_dir/larpercord" 2>/dev/null | grep 'not found' || true)"
glibc="$(ldd "$bin_dir/larpercord" 2>&1 | grep 'GLIBC_' || true)"
"$bin_dir/larpercord" --help >/dev/null 2>"$tmp/err" || glibc="$(cat "$tmp/err")"
if [ -n "$missing" ]; then
    echo "Missing system libraries:"
    echo "$missing"
    cmd=""
    if command -v pacman >/dev/null; then cmd="sudo pacman -S --needed sdl3 curl freetype2 fontconfig libwebp opus openssl"
    elif command -v dnf >/dev/null; then cmd="sudo dnf install SDL3 libcurl freetype fontconfig libwebp opus openssl-libs"
    elif command -v apt-get >/dev/null; then cmd="sudo apt-get install libsdl3-0 libcurl4 libfreetype6 libfontconfig1 libwebp7 libwebpdemux2 libopus0 libssl3"
    elif command -v zypper >/dev/null; then cmd="sudo zypper install libSDL3-0 libcurl4 libfreetype6 libfontconfig1 libwebp7 libwebpdemux2 libopus0 libopenssl3"
    fi
    if [ -n "$cmd" ]; then
        echo "To install them: $cmd"
        if [ -t 0 ]; then
            printf "Run it now? [y/N] "
            read -r answer
            case "$answer" in y|Y) $cmd ;; esac
        fi
    fi
elif [ -n "$glibc" ]; then
    echo "The published build does not run on this system:"
    echo "$glibc" | head -3
    echo "Build from source: https://github.com/$repo#build"
    exit 1
fi

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "Add $bin_dir to PATH to run it from a terminal." ;;
esac
echo "Done. Open it from your app menu or with: larpercord"
