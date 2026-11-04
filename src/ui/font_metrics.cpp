// As bindings em C do ImGui deixam ImFontBaked opaco (tem campos de bits), e a
// linha de base dos runs do `label` precisa do Ascent de cada fonte e tamanho.
#include "imgui.h"

extern "C" float larper_font_ascent(ImFont* font, float size) {
    return font->GetFontBaked(size)->Ascent;
}

// Quantas entradas a tabela de caracteres dessa fonte+tamanho tem (o QA confere
// que um emoji não reserva a tabela até U+1F600).
extern "C" int larper_font_index_size(ImFont* font, float size) {
    return font->GetFontBaked(size)->IndexLookup.Size;
}
