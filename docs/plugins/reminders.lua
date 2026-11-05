-- @name Reminders
-- @name:pt Lembretes
-- @description /remind 10m call back, or "Remind me" on a message. Notifies you when it's time, including after a restart.
-- @description:pt /remind 10m ligar de volta, ou "Lembrar" numa mensagem. Avisa na hora certa, mesmo depois de reabrir o app.
-- @version 1.0.0
-- @capabilities menu, panel, storage, timers, notify, messages

local tr = larper.tr
local MAX = 200
local list = larper.storage.get("list") or {}
local recent = {}
local next_id = larper.storage.get("next") or 1
local pending = nil -- a mensagem do "Lembrar", esperando o tempo
local timer = nil

local function save()
  larper.storage.set("list", list)
  larper.storage.set("next", next_id)
end

-- "10m", "1h30m", "2d", "45s", "90 min".
local units = { s = 1, seg = 1, sec = 1, m = 60, min = 60, h = 3600, d = 86400, dia = 86400, dias = 86400, day = 86400, days = 86400 }

local function parse_time(s)
  local total, found = 0, false
  for n, unit in s:gmatch("(%d+)%s*(%a+)") do
    local mult = units[unit:lower()]
    if not mult then return nil end
    total = total + tonumber(n) * mult
    found = true
  end
  if found and total > 0 and total <= 366 * 86400 then return total end
end

local function when(t)
  if os.date("%Y%m%d", t) == os.date("%Y%m%d") then return os.date("%H:%M", t) end
  return os.date(larper.lang() == "pt" and "%d/%m %H:%M" or "%b %d %H:%M", t)
end

local render
local arm

local function fire(r, late)
  local text = r.text ~= "" and r.text or tr("Lembrete", "Reminder")
  if late then text = text .. tr(" (atrasado)", " (late)") end
  -- Foi a própria pessoa que pediu: aparece mesmo com a janela em foco.
  larper.notify("⏰ " .. text, { desktop = true })
  table.insert(recent, 1, r)
  recent[11] = nil
end

local function check(late)
  local now = os.time()
  local i, fired = 1, false
  while i <= #list do
    if list[i].due <= now then
      fire(table.remove(list, i), late)
      fired = true
    else
      i = i + 1
    end
  end
  if fired then save() end
  arm()
  render()
end

-- Um temporizador só, para o próximo que vence.
arm = function()
  if timer then larper.cancel(timer) end
  timer = nil
  local nearest
  for _, r in ipairs(list) do
    if not nearest or r.due < nearest then nearest = r.due end
  end
  if nearest then
    timer = larper.after(math.max(nearest - os.time(), 0), function() check(false) end)
  end
end

local function add(seconds, text, m)
  if #list >= MAX then
    larper.notify(tr("Lembretes demais: até 200", "Too many reminders: up to 200"))
    return false
  end
  local r = { id = next_id, due = os.time() + seconds, text = text }
  next_id = next_id + 1
  if m then
    r.channel = m.channel.id
    r.message = m.id
  end
  list[#list + 1] = r
  table.sort(list, function(a, b) return a.due < b.due end)
  save()
  arm()
  render()
  larper.notify(tr("Vou lembrar às ", "I'll remind you at ") .. when(r.due))
  return true
end

local function cancel(id)
  for i, r in ipairs(list) do
    if r.id == id then
      table.remove(list, i)
      save()
      arm()
      render()
      return
    end
  end
end

local function row(r, past)
  return {
    title = r.text ~= "" and r.text or tr("Lembrete", "Reminder"),
    subtitle = r.message and tr("Clique para ir até a mensagem", "Click to go to the message") or "",
    meta = when(r.due),
    key = (past and "old" or "r") .. r.id,
    on_click = r.message and function() larper.jump(r.channel, r.message) end or nil,
    actions = not past and {
      { label = tr("Cancelar", "Cancel"), style = "danger", key = "cancel" .. r.id, on_click = function() cancel(r.id) end },
    } or nil,
  }
end

local function choose(seconds)
  local m = pending
  pending = nil
  add(seconds, m and m.text or "", m and m.msg or nil)
end

render = function()
  local tree = { title = tr("Lembretes", "Reminders") }
  if pending then
    tree[#tree + 1] = { type = "heading", text = tr("Lembrar desta mensagem", "Remind me about this message") }
    tree[#tree + 1] = { type = "text", text = pending.text, style = "muted" }
    tree[#tree + 1] = { type = "row",
      { type = "button", label = "10 min", key = "in10m", on_click = function() choose(600) end },
      { type = "button", label = "1 h", key = "in1h", on_click = function() choose(3600) end },
      { type = "button", label = "3 h", key = "in3h", on_click = function() choose(3 * 3600) end },
      { type = "button", label = tr("Amanhã", "Tomorrow"), key = "in1d", on_click = function() choose(86400) end },
    }
    tree[#tree + 1] = { type = "input", key = "custom", placeholder = tr("Ou escreva: 20m, 1h30m, 2d (Enter)", "Or type: 20m, 1h30m, 2d (Enter)"), clear = true,
      on_submit = function(v)
        local s = parse_time(v)
        if s then choose(s) else larper.notify(tr("Não entendi esse tempo", "I didn't get that time")) end
      end }
    tree[#tree + 1] = { type = "row",
      { type = "button", label = tr("Deixar para lá", "Never mind"), key = "pending-off", on_click = function() pending = nil; render() end },
    }
    tree[#tree + 1] = { type = "separator" }
  end
  local items = {}
  for _, r in ipairs(list) do items[#items + 1] = row(r, false) end
  tree[#tree + 1] = { type = "list", key = "list", items = items,
    empty = tr("Nenhum lembrete. Use /remind 10m texto, ou botão direito numa mensagem.", "No reminders. Use /remind 10m text, or right-click a message.") }
  if #recent > 0 then
    tree[#tree + 1] = { type = "heading", text = tr("Já avisados", "Already fired") }
    local old = {}
    for _, r in ipairs(recent) do old[#old + 1] = row(r, true) end
    tree[#tree + 1] = { type = "list", key = "recent", items = old }
  end
  larper.panel.set(tree)
end

larper.command("/remind", function(args)
  local spec, text = args:match("^(%S+)%s*(.*)$")
  local seconds = spec and parse_time(spec)
  -- "/remind 1h 30m texto": o tempo pode vir em dois pedaços.
  if seconds and text then
    local more, rest = text:match("^(%d+%a+)%s*(.*)$")
    if more and parse_time(more) then
      seconds = seconds + parse_time(more)
      text = rest
    end
  end
  if not seconds then
    larper.notify(tr("Use assim: /remind 10m ligar de volta", "Use it like this: /remind 10m call back"))
    return
  end
  add(seconds, text or "")
end)

larper.command("/reminders", function()
  render()
  larper.panel.open()
end)

larper.menu("message", { pt = "Lembrar desta mensagem", en = "Remind me" }, function(m)
  local text = m.content:gsub("%s+", " ")
  if #text > 120 then
    local cut = 120
    while cut > 0 and (text:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
    text = text:sub(1, cut) .. "…"
  end
  pending = { text = m.author.name .. ": " .. text, msg = m }
  render()
  larper.panel.open()
end)

-- Se a mensagem foi apagada, o lembrete fica, sem o texto dela.
larper.on("delete", function(d)
  local changed = false
  for _, r in ipairs(list) do
    if r.message == d.id then
      r.text = tr("(a mensagem foi apagada)", "(the message was deleted)")
      r.message = nil
      changed = true
    end
  end
  if changed then
    save()
    render()
  end
end)

larper.on("lang", function() render() end)

-- O que venceu com o app fechado avisa agora.
check(true)
