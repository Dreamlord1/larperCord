// As bindings em C do ImGui deixam ImFontBaked opaco (tem campos de bits), e a
// linha de base dos runs do `label` precisa do Ascent de cada fonte e tamanho.
#include "imgui.h"
#include "imgui_internal.h"

extern "C" float larper_font_ascent(ImFont* font, float size) {
    return font->GetFontBaked(size)->Ascent;
}

// Onde o ImGui quebra uma linha da caixa de texto com WordWrap (InputTextLineIndexBuild).
extern "C" const char* larper_input_wrap(ImFont* font, float size, const char* s, const char* end, float wrap) {
    return ImFontCalcWordWrapPositionEx(font, size, s, end, wrap, ImDrawTextFlags_WrapKeepBlanks);
}
