-- O exemplo da página inicial do site (site/landing.html): os dois precisam ser iguais.
-- @name CVE notes
-- @capabilities messages, decorate, http
-- @hosts cveawg.mitre.org
larper.on("message", function(msg)
  local id = msg.content:upper():match("CVE%-%d+%-%d+")
  if not id then return end
  larper.http.get("https://cveawg.mitre.org/api/cve/" .. id, function(res)
    local cve = res.ok and larper.json.decode(res.body)
    local cna = cve and cve.containers and cve.containers.cna
    if cna and cna.title then
      larper.decorate(msg.id, { note = id .. ": " .. cna.title })
    end
  end)
end, { contains = { "cve-" } })
