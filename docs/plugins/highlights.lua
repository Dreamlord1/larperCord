-- @name Highlights
-- @name:pt Destaques
-- @description Pick words to watch across all channels. When someone writes one you get a notification, and the panel keeps a history that takes you to the message.
-- @description:pt Escolha palavras para acompanhar em todos os canais. Quando alguém escreve uma, você recebe um aviso, e o painel guarda um histórico que leva à mensagem.
-- @version 1.0.0
-- @capabilities messages, panel, storage, notify, decorate

local tr = larper.tr
local MAX_HITS = 200
local words = larper.storage.get("words") or {}
-- Guardado no disco: onde e quem, nunca o texto de ninguém.
local hits = larper.storage.get("hits") or {}
-- O trecho da mensagem fica só na memória, e sai se ela for apagada.
local snippets = {}

local function fold(s)
  -- Minúsculas, inclusive as letras acentuadas.
  return (s:lower():gsub("\xC3([\x80-\x9E])", function(c) return "\xC3" .. string.char(c:byte() + 32) end))
end

-- Palavra inteira: nem "pizzaria" conta como "pizza", nem "c" dentro de "c++".
local function is_word(b)
  return b and (b >= 0x80 or b == 95 or (b >= 48 and b <= 57) or (b >= 97 and b <= 122))
end

local function has_word(text, w)
  local from = 1
  while true do
    local a, z = text:find(w, from, true)
    if not a then return false end
    if (not is_word(w:byte(1)) or not is_word(text:byte(a - 1))) and (not is_word(w:byte(-1)) or not is_word(text:byte(z + 1))) then
      return true
    end
    from = a + 1
  end
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function save()
  larper.storage.set("words", words)
  larper.storage.set("hits", hits)
end

local function when(t)
  if os.date("%Y%m%d", t) == os.date("%Y%m%d") then return os.date("%H:%M", t) end
  return os.date(larper.lang() == "pt" and "%d/%m %H:%M" or "%b %d %H:%M", t)
end

local render

local function add_word(w)
  w = fold(trim(w))
  if w == "" then return end
  for _, x in ipairs(words) do
    if x == w then return end
  end
  if #words >= 64 then
    larper.notify(tr("Palavras demais: até 64", "Too many words: up to 64"))
    return
  end
  words[#words + 1] = w
  save()
  render()
end

render = function()
  local word_items = {}
  for i, w in ipairs(words) do
    word_items[#word_items + 1] = {
      title = w, key = "w" .. i,
      actions = { { label = tr("Tirar", "Remove"), style = "danger", key = "rmw" .. i, on_click = function()
        table.remove(words, i)
        save()
        render()
      end } },
    }
  end
  local hit_items = {}
  for _, h in ipairs(hits) do
    hit_items[#hit_items + 1] = {
      title = h.author .. "  ·  #" .. h.channel_name,
      subtitle = snippets[h.id] or ("“" .. h.word .. "”"),
      meta = when(h.time),
      key = h.id,
      on_click = function() larper.jump(h.channel, h.id) end,
    }
  end
  local tree = {
    title = tr("Destaques", "Highlights"),
    { type = "input", key = "new", placeholder = tr("Nova palavra (Enter)", "New word (Enter)"), clear = true,
      on_submit = function(v) add_word(v) end },
    { type = "list", key = "words", items = word_items,
      empty = tr("Nenhuma palavra ainda. Escreva uma acima.", "No words yet. Type one above.") },
    { type = "heading", text = tr("Histórico", "History") },
    { type = "list", key = "hits", items = hit_items, empty = tr("Nada por enquanto.", "Nothing so far.") },
  }
  if #hits > 0 then
    tree[#tree + 1] = { type = "row",
      { type = "button", label = tr("Limpar histórico", "Clear history"), key = "clear", on_click = function()
        hits = {}
        snippets = {}
        save()
        render()
      end },
    }
  end
  larper.panel.set(tree)
end

larper.on("message", function(m)
  if m.mine or m.ignored or #words == 0 or m.content == "" then return end
  local text = fold(m.content)
  for _, w in ipairs(words) do
    if has_word(text, w) then
      local snippet = m.content:gsub("%s+", " ")
      if #snippet > 200 then
        local cut = 200
        while cut > 0 and (snippet:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
        snippet = snippet:sub(1, cut) .. "…"
      end
      snippets[m.id] = snippet
      table.insert(hits, 1, { id = m.id, channel = m.channel.id, channel_name = m.channel.name, author = m.author.name, word = w, time = m.time })
      if #hits > MAX_HITS then
        snippets[hits[#hits].id] = nil
        hits[#hits] = nil
      end
      save()
      render()
      larper.decorate(m, { badge = "★ " .. w })
      larper.notify("★ " .. w .. ": " .. m.author.name .. " #" .. m.channel.name)
      return
    end
  end
end)

larper.command("/highlights", function(args)
  if args ~= "" then add_word(args) end
  render()
  larper.panel.open()
end)

-- Apagaram: sai da lista, com o texto.
larper.on("delete", function(d)
  snippets[d.id] = nil
  for i, h in ipairs(hits) do
    if h.id == d.id then
      table.remove(hits, i)
      save()
      render()
      return
    end
  end
end)

larper.on("lang", render)
render()
