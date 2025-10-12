-- format a number with commas every 3rd digit
function format_number(n, precision)
  if precision then
    n = string.format("%."..precision.."f", n)
  else
    n = tostring(n)
  end
  local k = 1
  while k > 0 do
    n, k = n:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
  end
  return n
end

-- number parser that supports arithmetic
local lua_tonumber = tonumber
function tonumber(s)
  local success, num = pcall(function()
    -- check most common case first, faster than the general case
    if string.find(s, "^%d+$") then
      return lua_tonumber(s)
    -- with just these characters you can't execute arbitrary code
    elseif string.find(s, "^[%d%+%-%*/%(%)%.]+$") then
      return load("return "..s)()
    else
      error("not a number")
    end
  end)
  if not success or num == nil then
    error("not a number: "..s)
  end
  return num
end
