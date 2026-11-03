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
#include <malloc.h>
#include <poll.h>
#include <stdio.h>
#include <sys/stat.h>
#include <zlib.h>
#define CURL_DISABLE_TYPECHECK 1
#include <curl/curl.h>
