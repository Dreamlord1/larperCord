// As bindings em C do ImGui deixam ImFontBaked opaco (tem campos de bits), e a
// linha de base dos runs do `label` precisa do Ascent de cada fonte e tamanho.
#include "imgui.h"

extern "C" float larper_font_ascent(ImFont* font, float size) {
    return font->GetFontBaked(size)->Ascent;
}
