-- @name Snippets
-- @name:pt Trechos
-- @description Save texts you use often and put them in the message box with one click or /snip name. It never sends anything: you still press Enter.
-- @description:pt Guarde textos que você usa sempre e ponha na caixa de mensagem com um clique ou /snip nome. Nunca envia nada: quem aperta Enter é você.
-- @version 1.0.0
-- @capabilities panel, storage, composer, menu, notify

local tr = larper.tr
local items = larper.storage.get("items") or {}
local draft_name, draft_text = "", ""

local function save()
  larper.storage.set("items", items)
end

local function find(name)
  local low = name:lower()
  for i, it in ipairs(items) do
    if it.name:lower() == low then return i end
  end
end

local render

local function add(name, text)
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" or text == "" then
    larper.notify(tr("O trecho precisa de nome e texto", "A snippet needs a name and text"))
    return false
  end
  local i = find(name)
  if i then
    items[i].text = text
  else
    if #items >= 200 then
      larper.notify(tr("Trechos demais: até 200", "Too many snippets: up to 200"))
      return false
    end
    items[#items + 1] = { name = name, text = text }
    table.sort(items, function(a, b) return a.name:lower() < b.name:lower() end)
  end
  save()
  return true
end

local function commit()
  if add(draft_name, draft_text) then
    draft_name, draft_text = "", ""
  end
  render()
end

render = function()
  local list = {}
  for _, it in ipairs(items) do
    list[#list + 1] = {
      title = it.name,
      subtitle = it.text,
      key = it.name,
      on_click = function() larper.insert(it.text) end,
      actions = { { label = tr("Tirar", "Remove"), style = "danger", key = "rm" .. it.name, on_click = function()
        local i = find(it.name)
        if i then table.remove(items, i) end
        save()
        render()
      end } },
    }
  end
  larper.panel.set({
    title = tr("Trechos", "Snippets"),
    { type = "text", text = tr("Clique para pôr na caixa de mensagem.", "Click to put it in the message box."), style = "muted" },
    { type = "list", key = "items", items = list, empty = tr("Nenhum trecho ainda.", "No snippets yet.") },
    { type = "separator" },
    { type = "heading", text = tr("Novo trecho", "New snippet") },
    { type = "input", key = "name", placeholder = tr("Nome", "Name"), value = draft_name, on_change = function(v) draft_name = v end },
    { type = "input", key = "text", placeholder = tr("Texto", "Text"), value = draft_text, on_change = function(v) draft_text = v end,
      on_submit = function(v)
        draft_text = v
        commit()
      end },
    { type = "row",
      { type = "button", label = tr("Guardar", "Save"), key = "add", style = "accent", on_click = commit },
    },
  })
end

larper.command("/snip", function(args)
  if args == "" then
    render()
    larper.panel.open()
    return
  end
  local i = find(args)
  if i then
    larper.insert(items[i].text)
  else
    larper.notify(tr("Não há trecho com esse nome: ", "No snippet with that name: ") .. args)
  end
end)

larper.menu("message", { pt = "Guardar como trecho", en = "Save as snippet" }, function(m)
  draft_text = m.content
  draft_name = ""
  render()
  larper.panel.open()
end)

larper.on("lang", render)
render()
