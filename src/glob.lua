local aliases = {}
function register_alias(alias)
  table.insert(aliases, alias)
end

local function glob(ps, s)
  if not ps then
    error("glob: first arg is nil", 2)
  end
  if not s then
    error("glob: second arg is nil", 2)
  end

  -- special case for when you don't want a pattern to match anything
  if ps == "" then return false end

  ps = "|"..ps.."|"
  local i = #aliases
  while i >= 1 do
    ps = string.gsub(ps, "(|+)"..aliases[i].name.."(|+)", "%1"..aliases[i].pattern.."%2")
    i = i-1
  end

  i = 0
  for p in string.gmatch(ps, "[^|]+") do
    i = i+1
    p = string.gsub(p, "*", ".*")
    p = string.gsub(p, "-", "%%-")
    p = "^"..p.."$"
    local res = string.find(s, p)
    if res ~= nil then
      return i
    end
  end
  return false
end

return glob
