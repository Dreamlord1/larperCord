-- @name Translate
-- @name:pt Traduzir
-- @description Right-click a message to see a translation under it, in the app's language. The text goes to api.mymemory.translated.net (a free public service) only when you ask, and only after you approve the host below.
-- @description:pt Botão direito numa mensagem para ver a tradução embaixo dela, no idioma do app. O texto vai para api.mymemory.translated.net (um serviço público e gratuito) só quando você pede, e só depois de aprovar o host aqui embaixo.
-- @version 1.0.0
-- @capabilities menu, decorate, http, notify
-- @hosts api.mymemory.translated.net

local tr = larper.tr
local HOST = "api.mymemory.translated.net"
-- O serviço aceita até 500 bytes de cada vez.
local MAX = 480

local function cut(text)
  if #text <= MAX then return text, false end
  local n = MAX
  while n > 0 and (text:byte(n + 1) or 0) & 0xC0 == 0x80 do n = n - 1 end
  return text:sub(1, n), true
end

-- Sem as marcas de menção e emoji, que o serviço só estragaria.
local function clean(text)
  return (text:gsub("<a?:([%w_]+):%d+>", ":%1:"):gsub("<@[!&]?%d+>", "@…"):gsub("<#%d+>", "#…"))
end

-- Traduzidas agora: clicar de novo tira.
local shown = {}

larper.menu("message", { pt = "Traduzir", en = "Translate" }, function(m)
  if shown[m.id] then
    shown[m.id] = nil
    larper.undecorate(m)
    return
  end
  if not larper.http.allowed(HOST) then
    larper.notify(tr("Aprove " .. HOST .. " em Configurações → Plugins", "Approve " .. HOST .. " in Settings → Plugins"))
    return
  end
  local text, partial = cut(clean(m.content))
  if text:gsub("%s", "") == "" then
    larper.notify(tr("Essa mensagem não tem texto", "That message has no text"))
    return
  end
  larper.decorate(m, { note = tr("Traduzindo…", "Translating…") })
  local url = "https://" .. HOST .. "/get?q=" .. larper.urlencode(text) .. "&langpair=" .. larper.urlencode("Autodetect|" .. larper.lang())
  larper.http.get(url, function(res)
    local data = res.ok and larper.json.decode(res.body) or nil
    local out = data and data.responseData and data.responseData.translatedText
    -- O serviço responde 200 até quando recusa: o motivo fica em responseStatus, e
    -- o aviso dele vem no lugar da tradução. Nunca é para mostrar esse aviso.
    local refused = data and data.responseStatus ~= nil and tostring(data.responseStatus) ~= "200"
    if refused and type(out) == "string" and out:find("DISTINCT LANGUAGES", 1, true) then
      shown[m.id] = true
      larper.decorate(m, { note = tr("Essa mensagem já está no seu idioma", "That message is already in your language") })
      return
    end
    if refused or type(out) ~= "string" or out == "" then
      larper.decorate(m, { note = tr("Não consegui traduzir", "Couldn't translate") .. (res.error and " (" .. res.error .. ")" or "") })
      return
    end
    shown[m.id] = true
    if partial then out = out .. " […]" end
    larper.decorate(m, { note = "🌐 " .. out })
  end)
end)
