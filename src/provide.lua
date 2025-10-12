-- used as a placeholder for a value
-- tables are only equal to themselves so this essentially acts like a unique symbol
-- this is used in the provisions metatable
undefined = {}

-- provisions: a form of dependency injection inspired by algebraic effects
-- in essense `provide` creates globals that aren't actually global ("local globals")
-- and are instead scoped inside the specific function call
-- (as well as all threads summoned by said function call)
PROVISIONS = {}
setmetatable(PROVISIONS, {
  __index = function(t, key)
    for i = #t,1,-1 do
      if t[i][key] ~= nil then
        local v = t[i][key]
        if v == undefined then
          return nil
        else
          return v
        end
      end
    end
    error("BUG DETECTED: attempted to read unassigned provision key: "..key, 2)
  end,
  __newindex = function(t, key, val)
    for i = #t,1,-1 do
      if t[i][key] then
        if val == nil then
          t[i][key] = undefined
        else
          t[i][key] = val
        end
        return
      end
    end
    error("BUG DETECTED: attempted to set unassigned provision key: "..key, 2)
  end,
})

local function provide(values, f)
  local meta = getmetatable(PROVISIONS)
  setmetatable(PROVISIONS, {})
  local my_provisions = {}
  for i,v in ipairs(PROVISIONS) do
    my_provisions[i] = v
  end
  table.insert(my_provisions, values)
  setmetatable(PROVISIONS, meta)
  setmetatable(my_provisions, meta)

  local inner_provisions = my_provisions
  local outer_provisions = PROVISIONS

  local co = coroutine.create(f)
  local next_values = {}
  while true do
    outer_provisions = PROVISIONS
    PROVISIONS = inner_provisions
    local msg = {coroutine.resume(co, table.unpack(next_values))}
    inner_provisions = PROVISIONS
    PROVISIONS = outer_provisions

    local ok = msg[1]

    if ok then
      if coroutine.status(co) == "dead" then
        -- function has returned, pass the value up
        return table.unpack(msg, 2)
      else
        -- just a yield, pass values up
        next_values = {coroutine.yield(table.unpack(msg, 2))}
      end
    else
      error(msg[2], 0)
    end
  end
end

return provide
