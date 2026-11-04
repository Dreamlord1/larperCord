#!/usr/bin/env python3
"""Gera src/ui/emoji_data.zig (tabela de emoji do seletor e do autocompletar).

Só roda à mão, quando sai uma versão nova do Unicode; o app não usa a rede
para isso. Entradas (baixe numa pasta vazia e passe o caminho):
  emoji-test.txt  https://unicode.org/Public/emoji/latest/emoji-test.txt
  gemoji.json     https://raw.githubusercontent.com/github/gemoji/master/db/emoji.json
  pt.json         https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json/cldr-annotations-full/annotations/pt/annotations.json

Uso: python3 -I tools/gen_emoji.py <pasta> src/ui/emoji_data.zig
"""
import json, re, sys, unicodedata, pathlib

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])

gem = {}
for e in json.loads((src / "gemoji.json").read_text(encoding="utf-8")):
    gem[e["emoji"].replace("️", "")] = e
pt = json.loads((src / "pt.json").read_text(encoding="utf-8"))["annotations"]["annotations"]

def fold(s):
    s = unicodedata.normalize("NFKD", s.lower())
    return "".join(ch for ch in s if not unicodedata.combining(ch) and ch != "|")

def slug(s):
    s = fold(s)
    s = re.sub(r"[^a-z0-9]+", "_", s).strip("_")
    return s or "emoji"

GROUPS = [
    ("Smileys & Emotion", "Carinhas", "Smileys"),
    ("People & Body", "Pessoas", "People"),
    ("Animals & Nature", "Natureza", "Nature"),
    ("Food & Drink", "Comida", "Food"),
    ("Travel & Places", "Viagem", "Travel"),
    ("Activities", "Atividades", "Activities"),
    ("Objects", "Objetos", "Objects"),
    ("Symbols", "Símbolos", "Symbols"),
    ("Flags", "Bandeiras", "Flags"),
]
by_group = {g[0]: [] for g in GROUPS}
line_re = re.compile(r"^([0-9A-F ]+?)\s*;\s*([a-z-]+)\s*#\s*(\S+)\s+E[\d.]+\s+(.*)$")
group = None
for raw in (src / "emoji-test.txt").read_text(encoding="utf-8").splitlines():
    if raw.startswith("# group:"):
        group = raw.split(":", 1)[1].strip()
        continue
    m = line_re.match(raw)
    if not m or m.group(2) != "fully-qualified" or group not in by_group:
        continue
    cps = [int(x, 16) for x in m.group(1).split()]
    # Tom de pele padrão: as variações com modificador ficam de fora.
    if any(0x1F3FB <= cp <= 0x1F3FF for cp in cps):
        continue
    by_group[group].append(("".join(chr(cp) for cp in cps), m.group(4)))

lines, offsets, cats = [], [], []
seen_codes = set()
pos = 0
index = 0
for gname, pt_name, en_name in GROUPS:
    first = index
    for glyph, desc in by_group[gname]:
        g = gem.get(glyph.replace("️", ""))
        aliases = list(g["aliases"]) if g else []
        # O nome principal é um que dá para digitar depois de ":" (nada de +1).
        named = [a for a in aliases if re.fullmatch(r"[a-z0-9_]+", a)]
        code = named[0] if named else slug(desc)
        if code in seen_codes:
            code = slug(desc)
        n = 2
        base = code
        while code in seen_codes:
            code = f"{base}_{n}"
            n += 1
        seen_codes.add(code)
        words = [a for a in aliases if a != code] + (list(g["tags"]) if g else []) + [desc]
        en = " ".join(dict.fromkeys(fold(w) for w in words))
        ann = pt.get(glyph) or pt.get(glyph.replace("️", "")) or {}
        pw = (ann.get("tts") or []) + (ann.get("default") or [])[:6]
        ptxt = " ".join(dict.fromkeys(fold(w) for w in pw))
        rec = f"{glyph}|{code}|{en}|{ptxt}"
        offsets.append(pos)
        lines.append(rec)
        pos += len(rec.encode("utf-8")) + 1
        index += 1
    cats.append((pt_name, en_name, by_group[gname][0][0], first, index - first))
offsets.append(pos)

w = ["""//! Tabela de emoji: a lista Unicode inteira (sem as variações de tom de pele),
//! na ordem do Unicode. GERADO por tools/gen_emoji.py, não edite à mão.
//! Cada linha de `blob`: emoji|nome|palavras em inglês|palavras em português
//! (palavras em minúsculas e sem acento). `offsets[i]` é onde começa a linha i.
const std = @import("std");

pub const Category = struct { name: []const u8, name_en: []const u8, icon: []const u8, first: u16, count: u16 };

pub const categories = [_]Category{"""]
for p, e, icon, first, count in cats:
    w.append(f'    .{{ .name = "{p}", .name_en = "{e}", .icon = "{icon}", .first = {first}, .count = {count} }},')
w.append("};\n")
w.append(f"pub const count: u16 = {index};\n")
w.append("pub const offsets = [_]u32{")
for i in range(0, len(offsets), 16):
    w.append("    " + ", ".join(str(x) for x in offsets[i:i + 16]) + ",")
w.append("};\n")
w.append("pub const blob =")
for l in lines:
    w.append("    \\\\" + l)
w.append(";\n")
w.append((pathlib.Path(sys.argv[0]).resolve().parent / "emoji_data_tail.zig").read_text(encoding="utf-8"))
out.write_text("\n".join(w), encoding="utf-8")
print(index, "emoji,", pos, "bytes de texto")
