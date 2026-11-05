#!/usr/bin/env bash
# Compila o que a versão portátil para Linux leva dentro do binário, em .deps/linux
# (versões e hashes fixos; hash errado para tudo). Roda no CI, num Ubuntu antigo: é
# a glibc de lá que decide em quais distros o binário abre.
#   tools/linux_deps.sh && PKG_CONFIG_PATH=$PWD/.deps/linux/lib/pkgconfig zig build -Dportable=true
#
# SDL3: várias distros ainda não têm o pacote. Ela abre X11, Wayland e o áudio só ao
# rodar, então nada disso vira dependência do binário.
# curl: muitas distros trazem uma versão sem WebSocket.
# OpenSSL: vem dos pacotes do Ubuntu e entra estático (zig build -Dportable=true), porque
# as distros já estão trocando a versão da libssl. Os certificados continuam os da
# distro de quem usa (sys.curlTls).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$PWD/.deps/linux
dl=$out/dl
mkdir -p "$dl"
get() { # url sha256
    local f="$dl/$(basename "$1")"
    [ -f "$f" ] || curl -fsSL --retry 3 -o "$f" "$1"
    echo "$2  $f" | sha256sum -c --quiet -
    echo "$f"
}

f=$(get https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20.tar.gz f3bb06f55bed9557227a700af2ea62e49497ebdf58037732a731a5fb3ef8581f)
t=$(mktemp -d)
tar -xf "$f" -C "$t"
cmake -S "$t"/SDL3-* -B "$t/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$out" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON \
    -DSDL_DEPS_SHARED=ON \
    -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF
cmake --build "$t/build"
cmake --install "$t/build"
rm -rf "$t"

f=$(get https://curl.se/download/curl-8.23.0.tar.xz 8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5)
t=$(mktemp -d)
tar -xf "$f" -C "$t"
(
    cd "$t"/curl-*
    ./configure --prefix="$out" --libdir="$out/lib" \
        --disable-shared --enable-static --with-pic \
        --with-openssl --enable-websockets \
        --without-ca-bundle --without-ca-path --with-ca-fallback \
        --without-libpsl --without-brotli --without-zstd --without-nghttp2 --without-libidn2 --without-librtmp \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
        --disable-pop3 --disable-imap --disable-smtp --disable-gopher --disable-mqtt --disable-smb \
        --disable-manual --disable-docs
    make -j"$(nproc)"
    make install
)
rm -rf "$t"
rm -rf "$out/bin" "$out/share"
echo "pronto: $out"
