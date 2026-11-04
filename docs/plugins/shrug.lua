-- shrug.lua: /shrug [texto] manda o texto seguido de ¯\_(ツ)_/¯
-- Ex.: "/shrug sei lá" vira "sei lá ¯\_(ツ)_/¯" no canal aberto.
local shrug = "¯\\_(ツ)_/¯"

larper.command("/shrug", function(args)
  local texto = shrug
  if args ~= "" then texto = args .. " " .. shrug end
  larper.send(larper.channel(), texto)
end)
