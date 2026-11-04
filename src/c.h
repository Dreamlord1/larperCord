// Tudo que vem de C, traduzido de uma vez para o módulo Zig `c`.
#include <SDL3/SDL.h>
#include "dcimgui.h"
#include "dcimgui_impl_sdl3.h"
#include "dcimgui_impl_sdlrenderer3.h"
#include <fontconfig/fontconfig.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/inotify.h>
#include <unistd.h>
#include <dirent.h>
#include <arpa/inet.h>
#include <malloc.h>
#include <poll.h>
#include <stdio.h>
#include <sys/stat.h>
#include <zlib.h>
#define CURL_DISABLE_TYPECHECK 1
#include <curl/curl.h>
#include <webp/decode.h>
#include <webp/demux.h>
#include <opus/opus.h>
#include <dave/dave.h>
#define STBI_NO_STDIO
#include "stb_image.h"
/* GIF quadro a quadro (third_party/stb/stb_image.c). */
typedef int (*larper_gif_cb)(void *ud, const unsigned char *rgba, int w, int h, int delay_ms);
int larper_gif_frames(const unsigned char *data, int len, larper_gif_cb cb, void *ud);
