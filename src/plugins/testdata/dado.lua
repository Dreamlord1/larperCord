-- dado.lua: dados, moeda e decisões, com o resultado no canal.
--   /dado            um d6
--   /dado 2d20+3     dois d20, somando 3
--   /moeda           cara ou coroa
--   /escolhe a, b, c sorteia uma das opções
local function dado(args)
  local spec = args ~= "" and args:lower():gsub("%s", "") or "1d6"
  local n, faces, resto = spec:match("^(%d*)d(%d+)(.*)$")
  local extra = resto and (resto == "" and 0 or tonumber(resto:match("^[+-]%d+$")))
  n = tonumber(n) or 1
  faces = tonumber(faces)
  if not faces or not extra or n < 1 or n > 50 or faces < 2 or faces > 1000 then
    larper.notify("Use assim: /dado 2d20+3 (até 50 dados de até 1000 lados)")
    return
  end
  local soma, jogadas = extra, {}
  for i = 1, n do
    local v = math.random(faces)
    jogadas[i] = tostring(v)
    soma = soma + v
  end
  local conta = table.concat(jogadas, " + ")
  if extra ~= 0 then conta = conta .. string.format(" %+d", extra) end
  if n == 1 and extra == 0 then
    larper.send(nil, "🎲 " .. spec .. ": **" .. soma .. "**")
  else
    larper.send(nil, "🎲 " .. spec .. ": " .. conta .. " = **" .. soma .. "**")
  end
end

larper.command("/dado", dado)

larper.command("/moeda", function()
  larper.send(nil, "🪙 " .. (math.random(2) == 1 and "**Cara**" or "**Coroa**"))
end)

larper.command("/escolhe", function(args)
  local opcoes = {}
  for item in args:gmatch("[^,]+") do
    item = item:match("^%s*(.-)%s*$")
    if item ~= "" then opcoes[#opcoes + 1] = item end
  end
  if #opcoes < 2 then
    larper.notify("Use assim: /escolhe pizza, sushi, lasanha")
    return
  end
  larper.send(nil, "🤔 Entre " .. table.concat(opcoes, ", ") .. ": **" .. opcoes[math.random(#opcoes)] .. "**")
end)
