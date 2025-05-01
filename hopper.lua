
-- Copyright umnikos (Alex Stefanov) 2023-2025
-- Licensed under MIT license
local version = "v1.4.2 ALPHA20"

local til

local help_message = [[
hopper script ]]..version..[[, made by umnikos

example usage: 
  hopper *chest* *barrel* -not *:pink_wool 

for more info check out the repo:
  https://github.com/umnikos/hopper.lua]]

-- v1.4.2 changelog:
-- support for storage drawers, bottomless bundles, etc.

local function halt()
  while true do
    os.pullEvent("free_lunch")
    -- nom nom nom
  end
end

local function exitOnTerminate(f)
  local status, err = pcall(f)
  if status then
    return
  end
  if err == "Terminated" then
    return
  end
  return error(err,0)
end

-- algebraic effects; used when handling `options` and `filters`
-- In essense `provide` creates globals that aren't actually global
-- and are instead scoped inside the specific function call.
-- That way it's as if we passed `options` and filters` around everywhere
-- without actually having to do that

local request_header = "--REQUEST--"
local function request(key)
  return coroutine.yield(request_header, "fetch", key)
end

local function provide(values, f, top_level)
  if not top_level then
    coroutine.yield(request_header, "provider-push", values)
    local res = {f()}
    coroutine.yield(request_header, "provider-pop")
    return table.unpack(res)
  end

  local co = coroutine.create(f)
  local next_values = {}
  local provision_stack = {values}
  local stack_height = 1
  while true do
    local msg = {coroutine.resume(co, table.unpack(next_values))}
    local ok = msg[1]
    if ok then
      if coroutine.status(co) == "dead" then
        -- function has returned, pass the value up
        return table.unpack(msg,2)
      else
        -- function has yielded, check what it wants
        if msg[2] == request_header then
          -- it's a request for something
          local command = msg[3]
          if command == "provider-push" then
            stack_height = stack_height + 1
            provision_stack[stack_height] = msg[4]
            next_values = {}
          elseif command == "provider-pop" then
            provision_stack[stack_height] = nil
            stack_height = stack_height - 1
            next_values = {}
          elseif command == "fetch" then
            local key = msg[4]
            local val = nil
            for i=stack_height,1,-1 do
              val = provision_stack[i][key]
              if val ~= nil then break end
            end
            next_values = {val}
          else
            error("unknown command: "..command)
          end
        else
          -- not a request, propagate the yield up
          next_values = {coroutine.yield(table.unpack(msg,2))}
        end
      end
    else
      -- function errored
      error(msg[2],0)
    end
  end
end

-- for debugging purposes
local pretty = require("cc.pretty")
local pprint = pretty.pretty_print

local aliases = {}
local glob_memoize = {}
local function register_alias(alias)
  table.insert(aliases,alias)
  glob_memoize = {}
end
local function glob(ps, s, recurse)
  -- special case for when you don't want a pattern to match anything
  if ps == "" then return false end

  if not recurse then
    local id = ps..";"..s
    if not glob_memoize[id] then
      glob_memoize[id] = glob(ps,s,true)
    end
    return glob_memoize[id]
  end

  ps = "|"..ps.."|"
  local i = #aliases
  while i >= 1 do
    ps = string.gsub(ps, "(|+)"..aliases[i].name.."(|+)", "%1"..aliases[i].pattern.."%2")
    i = i - 1
  end

  i = 0
  for p in string.gmatch(ps, "[^|]+") do
    i = i + 1
    p = string.gsub(p,"*",".*")
    p = string.gsub(p,"-","%%-")
    p = "^"..p.."$"
    local res = string.find(s,p)
    if res ~= nil then
      return i
    end
  end
  return false
end

local function is_valid_name(s)
  return not string.find(s, "[^a-zA-Z_]")
end

local lua_tonumber = tonumber
local function tonumber(s)
  local success,num = pcall(function() 
    -- check most common case first, faster than the general case
    if string.find(s,"^%d+$") then
      return lua_tonumber(s)
    -- with just these characters you can't execute arbitrary code
    elseif string.find(s,"^[%d%+%-%*/%(%)%.]+$") then
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

local cursor_x,cursor_y = 1,1
local function save_cursor(options)
  cursor_x,cursor_y = term.getCursorPos()
  local sizex,sizey = term.getSize()
  local margin
  if options.debug then margin=2 else margin=2 end
  cursor_y = math.min(cursor_y, sizey-margin)
end
local function clear_below()
  local _,y = term.getCursorPos()
  local _,sizey = term.getSize()
  while y < sizey do
    y = y + 1
    term.setCursorPos(1,y)
    term.clearLine()
  end
end
local function go_back()
  term.setCursorPos(cursor_x,cursor_y)
end

local function format_time(time)
  if time < 1000*60*60 then -- less than an hour => format as minutes and seconds
    local seconds = math.floor(time/1000)
    local minutes = math.floor(seconds/60)
    seconds = seconds - 60*minutes
    return minutes.."m "..seconds.."s"
  else -- format as hours and minutes
    local minutes = math.floor(time/1000/60)
    local hours = math.floor(minutes/60)
    minutes = minutes - 60*hours
    return hours.."h "..minutes.."m"
  end
end

-- `-storage` objects and a set of peripherals they wrap
-- this is filled up at the start of hopper_loop
local storages = {}
-- list of peripherals that are part of a storage, not to be used directly ever
local peripheral_blacklist = {}

local function display_exit(options, args_string)
  local start_time = request("start_time")
  if options.quiet then
    return
  end
  local total_transferred = request("report_transfer")(0)
  local elapsed_time = 0
  if start_time then
    elapsed_time = os.epoch("utc")-start_time
  end
  local ips = (total_transferred*1000/elapsed_time)
  if ips ~= ips then
    ips = 0
  end
  local ips_rounded = math.floor(ips*100)/100
  go_back()
  if options.debug then
    print("           ")
  end
  print("total uptime: "..format_time(elapsed_time))
  print("transferred total: "..total_transferred.." ("..ips_rounded.." i/s)    ")
end

local latest_error = nil
local function display_loop(options, args_string)
  if options.quiet then 
    halt()
  end
  local get_hoppering_stage = request("get_hoppering_stage")
  local start_time = request("start_time")
  term.clear()
  go_back()
  print("hopper.lua "..version)
  args_string = args_string:gsub(" / ","\n/ ")
  print("$ hopper "..args_string)
  print("")
  save_cursor(options)

  local time_to_wake = start_time/1000
  while true do
    local total_transferred = request("report_transfer")(0)
    local elapsed_time = os.epoch("utc")-start_time
    local ips = (total_transferred*1000/elapsed_time)
    if ips ~= ips then
      ips = 0
    end
    local ips_rounded = math.floor(ips*100)/100
    go_back()
    if options.debug then
      print((get_hoppering_stage() or "nilstate").."        ")
    end
    print("uptime: "..format_time(elapsed_time).."    ")
    if latest_error then
      term.clearLine()
      print("")
      print(latest_error)
    else
      term.write("transferred so far: "..total_transferred.." ("..ips_rounded.." i/s)    ")
      clear_below()
    end
    if options.debug then
      sleep(0)
    else
      local current_time = os.epoch("utc")/1000
      time_to_wake = time_to_wake + 1
      sleep(time_to_wake - current_time)
    end
  end
end

-- if the computer has storage (aka. is a turtle)
-- we'd like to be able to transfer to it
local function determine_self()
  if not turtle then return nil end
  local modems = {}
  local modem_count = 0
  for _,dir in ipairs({"top","front","bottom","back","right","left"}) do
    local p = peripheral.wrap(dir)
    if p and p.getNameLocal then
      modem_count = modem_count + 1
      modems[dir] = p
    end
  end

  local singular_name
  if modem_count == 1 then
    for _,modem in pairs(modems) do
      singular_name = modem.getNameLocal()
    end
  end

  local lookup_table = {}
  if modem_count >= 2 then
    for _,modem in pairs(modems) do
      local sided_name = modem.getNameLocal()
      local chests = modem.getNamesRemote()
      for _,c in ipairs(chests) do
        lookup_table[c]=sided_name
      end
    end
  end

  -- we return a function that tells you the turtle's peripheral name
  -- based on what chest you want to transfer from/to
  return function(chest)
    if modem_count == 0 then
      error("No modems were found next to the turtle!")
    end
    if modem_count == 1 then
      return singular_name
    end
    return lookup_table[chest]
  end
end

local turtle_original_slot
local turtle_semaphore = 0
local function turtle_save_slot()
  if not turtle then return end
  -- only save if we haven't saved already
  -- this way we can just save before every turtle.select()
  if not turtle_original_slot then
    turtle_original_slot = turtle.getSelectedSlot()
  end
end
local function turtle_restore_slot()
  if not turtle then return end
  if turtle_original_slot then
    turtle.select(turtle_original_slot)
    turtle_original_slot = nil
  end
end

local function turtle_lock()
  turtle_semaphore = turtle_semaphore + 1
end
local function turtle_unlock()
  turtle_semaphore = turtle_semaphore - 1
  if turtle_semaphore == 0 then
    turtle_restore_slot()
  end
end

local function turtle_transfer(from,to,count)
  turtle_save_slot()
  -- FIXME: optimize this for faster transfers
  -- by keeping track of what slot is selected
  turtle.select(from)
  -- this doesn't return how many items were moved
  turtle.transferTo(to,count)
  -- so we'll just trust that the math we used to get `count` is correct
  return count
end

-- map of name->type
-- keeps track of whether things are items, fluids, or something else
-- items have a type nil
-- fluids have a type "f"
local item_types = {}


-- slot data structure: 
-- chest_name: name of container holding that slot
-- slot_number: the index of that slot in the chest
-- name: name of item held in slot, nil if empty
-- nbt: nbt hash of item, nil if none
-- count: how much is there of this item, 0 if none
-- limit: how many items the slot can store, serves as an override for stack size cache
-- is_source: whether this slot matches source slot critera
-- is_dest: whether this slot matches dest slot criteria
-- cannot_wrap: the chest this slot is in cannot be wrapped
-- must_wrap: the chest this slot is in must be wrapped
-- after_action: identifies that some special action must be done after transferring to this slot
-- voided: how many of the items are physically there but are pretending to be missing
-- from_priority/to_priority: how early in the pattern match the chest appeared, lower number means higher priority

local function matches_filters(slot)
  local filters = request("filters")
  local options = request("options")
  if slot.name == nil then
    error("SLOT NAME IS NIL")
  end

  local res = nil
  if #filters == 0 then 
    res = true
  else
    res = false
    for _,filter in pairs(filters) do
      local match = true
      if filter.name and not glob(filter.name,slot.name) then
        match = false
      end
      if filter.nbt and not (slot.nbt and glob(filter.nbt,slot.nbt)) then
        match = false
      end
      if match then
        res = true
        break
      end
    end
  end
  if options.negate then
    return not res
  else 
    return res
  end
end

-- returns if container is an UnlimitedPeripheralWorks container
local function isUPW(c)
  -- cannot wrap storages so they're hardcoded
  if storages[c] then
    return false
  end
  if type(c) == "string" then
    c = peripheral.wrap(c)
  end
  if not c then
    -- anything else not wrappable is also probably some exception
    return false
  end
  if c.items then
    return true
  else
    return false
  end
end

local function isMEBridge(c)
  if storages[c] then
    return false
  end
  if type(c) == "string" then
    c = peripheral.wrap(c)
  end
  if not c then
    -- anything else not wrappable is also probably some exception
    return false
  end
  if c.importFluidFromPeripheral then
    return true
  else
    return false
  end
end

local limits_cache = {}
local no_c = {
  list = function() return nil end,
  size = function() return 0 end
}

local function chest_wrap(chest, recursed)
  if not recursed then
    local chest_wrap_cache = request("chest_wrap_cache")
    if not chest_wrap_cache[chest] then
      chest_wrap_cache[chest] = {chest_wrap(chest, true)}
    end
    return table.unpack(chest_wrap_cache[chest])
  end
  local options = request("options")
  -- for every possible chest must have .list and .size
  -- as well as returning cannot_wrap, must_wrap, and after_action
  local cannot_wrap = false
  local must_wrap = false
  local after_action = false
  if chest == "void" then
    local c = {
      list=function() return {} end,
      size=function() return 1 end
    }
    cannot_wrap = true
    must_wrap = true
    after_action = true
    return c, cannot_wrap, must_wrap, after_action
  end
  if chest == "self" then
    cannot_wrap = true
    local c = {
      list = function()
        local l = {}
        for i=1,16 do
          l[i] = turtle.getItemDetail(i,false)
          if l[i] then
            if limits_cache[l[i].name] == nil then
              local details = turtle.getItemDetail(i,true)
              l[i] = details
              if details ~= nil then
                limits_cache[details.name] = details.maxCount
              end
            end
            if l[i] then
              l[i].limit = limits_cache[l[i].name]
            end
          end
        end
        return l
      end,
      size = function() return 16 end
    }
    return c, cannot_wrap, must_wrap, after_action
  end
  if storages[chest] then
    after_action = true
    must_wrap = true
    local c = storages[chest]
    local cc = {
      size = function() return 1+#c.list() end,
      list = function()
        local l = c.list()
        for _,v in pairs(l) do
          v.limit = 1/0
        end
        return l
      end,
      pushItems = c.pushItems,
      pullItems = c.pullItems,
      transfer = c.transfer
    }
    return cc, cannot_wrap, must_wrap, after_action
  end
  local c = peripheral.wrap(chest)
  if not c then
    --error("failed to wrap "..chest_name)
    return no_c, cannot_wrap, must_wrap, after_action
  end
  if c.ejectDisk then
    -- this a disk drive
    c.ejectDisk()
    cannot_wrap = true
    after_action = true
    c.list = function() return {} end
    c.size = function() return 1 end
    return c, cannot_wrap, must_wrap, after_action
  end
  if c.getInventory and not c.list then
    -- this is a bound introspection module
    must_wrap = true
    local success
    if options.ender then
      success, c = pcall(c.getEnder)
    else
      success, c = pcall(c.getInventory)
    end
    if not success then
      return no_c, cannot_wrap, must_wrap, after_action
    end
  end
  if c.getPatternsFor and not c.items then
    -- incorrectly wrapped AE2 system, UPW bug (computer needs to be placed last)
    error("Cannot wrap AE2 system correctly! Break and place this computer and try again.")
  end
  if isMEBridge(chest) then
    -- ME bridge from Advanced Peripherals
    if options.denySlotless then
      error("cannot use "..options.denySlotless.." when transferring to/from ME bridge")
    end

    must_wrap = true -- special methods must be used
    after_action = true
    c.list = function()
      local res = {}
      res = c.listItems()
      for _,i in pairs(res) do
        i.nbt = nil -- FIXME: figure out how to hash the nbt
        i.count = i.count or i.amount
        i.limit = 1/0 -- FIXME: special-case willing_to_take
      end
      -- ME bridge doesn't support importing/exporting fluids I think?
      -- for _,fluid in pairs(c.listFluid()) do
      --   table.insert(res,{
      --     name=fluid.name,
      --     count=math.max(fluid.amount,1),
      --     maxCount=1/0,
      --   })
      --   item_types[fluid.name] = "f"
      -- end
      return res
    end
    c.getItemDetail = function(n)
      return c.list()[n]
    end
    c.size = function()
      local s = 1+#c.list()
      return s
    end
    c.pushItems = function(other_peripheral,from_slot_identifier,count,to_slot_number,additional_info)
      local item_name = string.match(from_slot_identifier,"[^;]*")
      return c.exportItemToPeripheral({name=item_name,count=count}, other_peripheral)
    end
    c.pullItems = function(other_peripheral,from_slot_number,count,to_slot_number,additional_info)
      local item_name = nil
      for _,s in pairs(additional_info) do
        item_name = s.name
        break
      end
      return c.importItemFromPeripheral({name=item_name,count=count},other_peripheral)
    end
  end
  if isUPW(c) then
    -- this is an UnlimitedPeripheralWorks inventory
    if options.denySlotless then
      error("cannot use "..options.denySlotless.." when transferring to/from UPW peripheral")
    end

    must_wrap = true -- UPW forces us to use its own functions when interacting with a regular inventory
    after_action = true
    c.list = function()
      local res = {}
      if c.items then
        res = c.items()
      end
      return res
    end
    c.getItemDetail = function(n)
      local i = c.list()[n]
      if item_types[i.name] == "f" then
        return i
      end
      if c.getItemDetailForge then
        return c.getItemDetailForge(n)
      end
      return i
    end
    c.pushItems = function(other_peripheral,from_slot_identifier,count,to_slot_number,additional_info)
      local item_name = string.match(from_slot_identifier,"[^;]*")
      return c.pushItem(other_peripheral,item_name,count)
    end
    c.pullItems = function(other_peripheral,from_slot_number,count,to_slot_number,additional_info)
      local item_name = nil
      for _,s in pairs(additional_info) do
        item_name = s.name
        break
      end
      return c.pullItem(other_peripheral,item_name,count)
    end
  end
  if not (c.list or c.tanks) then
    -- failed to wrap it for some reason
    return no_c, cannot_wrap, must_wrap, after_action
  end
  local cc = {}
  cc.list= function()
    local l = {}
    if c.list then
      l = c.list()
    end
    for i,item in pairs(l) do
      if limits_cache[item.name] == nil then
        -- 1.12 cc + plethora calls getItemDetail "getItemMeta"
        if not c.getItemDetail then
          c.getItemDetail = c.getItemMeta
        end

        local details = c.getItemDetail(i)
        l[i] = details
        if details ~= nil then
          limits_cache[details.name] = details.maxCount
        end
      end
      if l[i] then
        l[i].limit = l[i].limit or limits_cache[item.name]

        local s = cc.size()
        if s==1 or s==2 or s==4 then
          -- possibly infinite
          l[i].limit = 1/0
        end
      end
    end
    local fluid_start = #l
    if c.tanks then
      after_action = true -- to reset size
      for fi,fluid in pairs(c.tanks()) do
        if fluid.name ~= "minecraft:empty" then -- I shouldn't need to do this, but alas...
          table.insert(l, fluid_start+fi, {
            name=fluid.name,
            count=math.max(fluid.amount,1), -- api rounds all amounts down, so amounts <1mB appear as 0, yet take up space
            limit=1/0, -- not really, but there's no way to know the real limit
          })
          item_types[fluid.name] = "f"
        end
      end
    end
    return l
  end
  cc.size=function() 
    local size = 0
    if cc.size_cache then
      size = cc.size_cache
    else
      if c.size then
        size = size + c.size()
      end
      cc.size_cache = size
    end
    if c.tanks then
      -- fluids. this is normally cacheable except
      -- some things like AE2 have their amount of tanks vary
      size = size + #c.tanks() + 1
    end
    if c.list and not c.size then
      -- UPW
      size = size + #c.list() + 1
    end
    return size
  end
  cc.pullItems=c.pullItems
  cc.pushItems=c.pushItems
  cc.pushFluid=c.pushFluid
  return cc, cannot_wrap, must_wrap, after_action
end

local function chest_list(chest)
  local c, cannot_wrap, must_wrap, after_action = chest_wrap(chest)
  return c.list(), cannot_wrap, must_wrap, after_action
end

local function chest_size(chest)
  local c = chest_wrap(chest)
  return c.size() or 0
end

local function transfer(from_slot,to_slot,count)
  local self = request("self")
  if count <= 0 then
    return 0
  end
  if from_slot.chest_name == nil or to_slot.chest_name == nil then
    error("NIL CHEST")
  end
  if item_types[from_slot.name] == "f" then
    -- fluids are to be dealt with here, separately.
    if not isMEBridge(from_slot.chest_name) and not isMEBridge(to_slot.chest_name) then
      if from_slot.count == count then
        count = count + 1 -- handle stray millibuckets that weren't shown
      end
      return chest_wrap(from_slot.chest_name).pushFluid(to_slot.chest_name,count,from_slot.name)
    end
    error("CANNOT DO FLUID TRANSFER BETWEEN "..from_slot.chest_name.." AND "..to_slot.chest_name)
  end
  if storages[from_slot.chest_name] and storages[to_slot.chest_name] then
    -- storage to storage transfer
    return storages[from_slot.chest_name].transfer(storages[to_slot.chest_name],from_slot.name,from_slot.nbt,count)
  end
  if (not from_slot.cannot_wrap) and (not to_slot.must_wrap) then
    local other_peripheral = to_slot.chest_name
    if other_peripheral == "self" then other_peripheral = self(from_slot.chest_name) end
    local c = chest_wrap(from_slot.chest_name)
    if not c then
      return 0
    end
    local from_slot_number = from_slot.slot_number
    local additional_info = nil
    if storages[from_slot.chest_name] or isUPW(from_slot.chest_name) or isMEBridge(from_slot.chest_name) then
      from_slot_number = from_slot.name..";"..(from_slot.nbt or "")
      additional_info = {[to_slot.slot_number]={name=to_slot.name,nbt=to_slot.nbt,count=to_slot.count}}
    end
    return c.pushItems(other_peripheral,from_slot_number,count,to_slot.slot_number,additional_info)
  end
  if (not to_slot.cannot_wrap) and (not from_slot.must_wrap) then
    local other_peripheral = from_slot.chest_name
    if other_peripheral == "self" then other_peripheral = self(to_slot.chest_name) end
    local c = chest_wrap(to_slot.chest_name)
    if not c then
      return 0
    end
    local additional_info = nil
    if storages[to_slot.chest_name] or isUPW(to_slot.chest_name) or isMEBridge(to_slot.chest_name) then
      additional_info = {[from_slot.slot_number]={name=from_slot.name,nbt=from_slot.nbt,count=from_slot.count}}
    end
    return c.pullItems(other_peripheral,from_slot.slot_number,count,to_slot.slot_number,additional_info)
  end
  if to_slot.chest_name == "void" then
    -- the void consumes all that you give it
    return count
  end
  if from_slot.chest_name == "self" and to_slot.chest_name == "self" then
    return turtle_transfer(from_slot.slot_number, to_slot.slot_number,count)
  end
  if isUPW(from_slot.chest_name) and isUPW(to_slot.chest_name) then
    -- FIXME: use chest_wrap to shorten this? (at the cost of performance)
    local c = peripheral.wrap(from_slot.chest_name)
    if c.pushItem then
      return c.pushItem(to_slot.chest_name,from_slot.name,count)
    else
      -- forge
      return c.pushItems(to_slot.chest_name,from_slot.slot_number,count,to_slot.slot_number)
    end
  end
  -- TODO: transfer between UPW and storages
  error("CANNOT DO TRANSFER BETWEEN "..from_slot.chest_name.." AND "..to_slot.chest_name)
end

local function mark_sources(slots,from) 
  local filters = request("filters")
  local options = request("options")
  for _,s in ipairs(slots) do
    if glob(from,s.chest_name) then
      s.is_source = true
      if options.from_slot then
        local any_match = false
        for _,slot in ipairs(options.from_slot) do
          if type(slot) == "number" and s.slot_number == slot then
            any_match = true
            break
          elseif type(slot) == "table" and slot[1] <= s.slot_number and s.slot_number <= slot[2] then
            any_match = true
            break
          end
        end
        s.is_source = any_match
      end
    end
  end
end

local function mark_dests(slots,to) 
  local filters = request("filters")
  local options = request("options")
  for _,s in ipairs(slots) do
    if glob(to,s.chest_name) then
      s.is_dest = true
      if options.to_slot then
        local any_match = false
        for _,slot in ipairs(options.to_slot) do
          if type(slot) == "number" and s.slot_number == slot then
            any_match = true
            break
          elseif type(slot) == "table" and slot[1] <= s.slot_number and s.slot_number <= slot[2] then
            any_match = true
            break
          end
        end
        s.is_dest = any_match
      end
    end
  end
end

local function unmark_overlap_slots(slots)
  local options = request("options")
  for _,s in ipairs(slots) do
    if s.is_source and s.is_dest then
      -- TODO: option to choose how this gets resolved
      -- currently defaults to being dest
      s.is_source = false
    end
  end
end

local function limit_slot_identifier(limit,primary_slot,other_slot)
  local options = request("options")
  local slot = {}
  slot.chest_name = primary_slot.chest_name
  slot.slot_number = primary_slot.slot_number
  slot.name = primary_slot.name
  slot.nbt = primary_slot.nbt
  if other_slot == nil then other_slot = {} end
  if slot.name == nil then
    slot.name = other_slot.name
    slot.nbt = other_slot.nbt
  end
  if slot.name == nil then
    error("limit_slot_identifier was given two empty slots",2)
  end
  local identifier = ""
  if limit.per_chest then
    identifier = identifier..slot.chest_name
  end
  identifier = identifier..";"
  if limit.per_slot then
    if slot.chest_name ~= "void" and not storages[slot.chest_name] then
      identifier = identifier..slot.slot_number
    end
  end
  identifier = identifier..";"
  if limit.per_name then
    identifier = identifier..slot.name
  end
  identifier = identifier..";"
  if limit.per_nbt then
    identifier = identifier..(slot.nbt or "")
  end
  identifier = identifier..";"
  if not limit.count_all then
    if not matches_filters(slot) then
      identifier = identifier.."x"
    end
  end

  return identifier
end

-- limit data structure
-- type: transfer/from/to
-- dir: direction; min/max for from/to
-- limit: the set amount that was specified to limit to
-- items: cache of item counts, indexed with an identifier

local function inform_limit_of_slot(limit,slot)
  local options = request("options")
  if slot.name == nil then return end
  if limit.type == "transfer" then return end
  if limit.type == "from" and (not slot.is_source) then return end
  if limit.type == "to" and (not slot.is_dest) then return end
  -- from and to limits follow
  local identifier = limit_slot_identifier(limit,slot)
  limit.items[identifier] = (limit.items[identifier] or 0) + slot.count
end

local function inform_limit_of_transfer(limit,from,to,amount)
  local options = request("options")
  local from_identifier = limit_slot_identifier(limit,from,to)
  local to_identifier = limit_slot_identifier(limit,to,from)
  if limit.items[from_identifier] == nil then
    limit.items[from_identifier] = 0
  end
  if limit.items[to_identifier] == nil then
    limit.items[to_identifier] = 0
  end
  if limit.type == "transfer" then
    limit.items[from_identifier] = limit.items[from_identifier] + amount
    if from_identifier ~= to_identifier then
      if to.chest_name ~= "void" then
        limit.items[to_identifier] = limit.items[to_identifier] + amount
      end
    end
  elseif limit.type == "from" then
    limit.items[from_identifier] = limit.items[from_identifier] - amount
  elseif limit.type == "to" then
    limit.items[to_identifier] = limit.items[to_identifier] + amount
  else
    error("UNKNOWN LIMIT TYPE "..limit.type)
  end
end

local function willing_to_give(slot)
  local options = request("options")
  if not slot.is_source then
    return 0
  end
  if slot.name == nil then
    return 0
  end
  local allowance = slot.count - (slot.voided or 0)
  for _,limit in ipairs(options.limits) do
    if limit.type == "from" then
      local identifier = limit_slot_identifier(limit,slot)
      limit.items[identifier] = limit.items[identifier] or 0
      local amount_present = limit.items[identifier]
      if limit.dir == "min" then
        allowance = math.min(allowance, amount_present - limit.limit)
      else
        if amount_present > limit.limit then
          allowance = 0
        end
      end
    elseif limit.type == "transfer" then
      local identifier = limit_slot_identifier(limit,slot)
      limit.items[identifier] = limit.items[identifier] or 0
      local amount_transferred = limit.items[identifier]
      allowance = math.min(allowance, limit.limit - amount_transferred)
    end
  end
  return math.max(allowance,0)
end

local function willing_to_take(slot,source_slot)
  local options = request("options")
  if not slot.is_dest then
    return 0
  end
  local stack_size = limits_cache[source_slot.name]
  if not stack_size and storages[source_slot.chest_name] then
    -- FIXME: make a til method for this query
    stack_size = storages[source_slot.chest_name].getStackSize(source_slot.name)
  end
  if not stack_size and isMEBridge(source_slot.chest_name) then
    -- that bs doesn't give us a maxCount so we just gotta make shit up
    -- there are two options:
    -- 1. transfer 1 item, get its maxCount, then transfer the rest
    -- 2. transfer as many items as can go and forget about maxCount
    -- option 2 is more efficient, but completely wrecks all of the slot caches
    -- and pretty much guarantees an error happens
    -- we go with option 2.
    stack_size = 1/0
  end
  local allowance
  if storages[slot.chest_name] then
    -- fake slot from a til storage
    -- TODO: implement limits for storages (at least transfer limits)
    storages[slot.chest_name].informStackSize(source_slot.name,stack_size)
    allowance = storages[slot.chest_name].spaceFor(source_slot.name, source_slot.nbt)
  elseif slot.chest_name == "void" then
    -- fake void slot, infinite limit
    allowance = 1/0
  else
    -- real regular slot
    allowance = (slot.limit or stack_size or (1/0)) - slot.count
  end
  for _,limit in ipairs(options.limits) do
    if limit.type == "to" then
      local identifier = limit_slot_identifier(limit,slot,source_slot)
      limit.items[identifier] = limit.items[identifier] or 0
      local amount_present = limit.items[identifier]
      if limit.dir == "max" then
        allowance = math.min(allowance, limit.limit - amount_present)
      else
        if amount_present < limit.limit then
          allowance = 0
        end
      end
    elseif limit.type == "transfer" then
      local identifier = limit_slot_identifier(limit,slot,source_slot)
      limit.items[identifier] = limit.items[identifier] or 0
      local amount_transferred = limit.items[identifier]
      allowance = math.min(allowance, limit.limit - amount_transferred)
    end
  end
  return math.max(allowance,0)
end

local function sort_sources(sources)
  table.sort(sources, function(left, right) 
    if left.from_priority ~= right.from_priority then
      return left.from_priority < right.from_priority
    elseif left.count - (left.voided or 0) ~= right.count - (right.voided or 0) then
      return left.count - (left.voided or 0) < right.count - (right.voided or 0)
    elseif left.chest_name ~= right.chest_name then
      return left.chest_name < right.chest_name
    elseif left.slot_number ~= right.slot_number then
      return left.slot_number > right.slot_number -- TODO: make this configurable
    elseif left.name ~= right.name then
      return left.name < right.name
    elseif left.nbt ~= right.nbt then
      return left.nbt < right.nbt
    end
  end)
end

local function sort_dests(dests)
  table.sort(dests, function(left, right)
    if left.to_priority ~= right.to_priority then
      return left.to_priority < right.to_priority
    elseif (left.limit - left.count) ~= (right.limit - right.count) then
      return (left.limit - left.count) < (right.limit - right.count)
    elseif left.chest_name ~= right.chest_name then
      return left.chest_name < right.chest_name
    elseif left.slot_number ~= right.slot_number then
      return left.slot_number < right.slot_number -- different here
    elseif left.name ~= right.name then
      if left.name == nil then
        return false
      end
      if right.name == nil then
        return true
      end
      return left.name < right.name
    elseif left.nbt ~= right.nbt then
      return left.nbt < right.nbt
    end
  end)
end

local function after_action(d,s,transferred,dests,di)
  if d.chest_name == "void" then
    s.count = s.count + d.count
    s.voided = (s.voided or 0) + d.count
    d.count = 0
    d.name = nil
    d.nbt = nil
    d.limit = 1/0
    return
  end
  -- FIXME: UPW nonsense should be getting its own code and methods here
  -- it's not entirely clear if this works perfectly or not
  if storages[d.chest_name] or isUPW(d.chest_name) or isMEBridge(d.chest_name) or item_types[s.name] == "f" then
    if d.count == transferred then
      local dd = {}
      for k,v in pairs(d) do
        dd[k] = v
      end
      dd.count = 0
      dd.name = nil
      dd.nbt = nil
      dd.limit = 1/0
      dd.slot_number = d.slot_number + 1
      -- insert it right after the empty slot that just got filled
      table.insert(dests, di+1, dd)
    end
    return
  end
  local c = peripheral.wrap(d.chest_name)
  if c.ejectDisk then
    c.ejectDisk()
    d.count = 0
    return
  end

  error(d.chest_name.." does not have an after_action")
end

local coroutine_lock = false

local latest_warning = nil -- used to update latest_error if another error doesn't show up

local function hopper_step(from,to,retrying_from_failure)
  local options = request("options")
  local filters = request("filters")
  local self = request("self")
  local set_hoppering_stage = request("set_hoppering_stage")
  local report_transfer = request("report_transfer")
  -- TODO: get rid of warning and error globals 
  latest_warning = nil

  set_hoppering_stage("look")
  local peripherals = {}
  table.insert(peripherals,"void")
  if self then
    table.insert(peripherals,"self")
  end
  for p,_ in pairs(storages) do
    if (glob(from,p) or glob(to,p)) then
      table.insert(peripherals,p)
    end
  end
  for _,p in ipairs(peripheral.getNames()) do
    if (glob(from,p) or glob(to,p)) and not peripheral_blacklist[p] then
      table.insert(peripherals,p)
    end
  end

  set_hoppering_stage("scan")
  for _,limit in ipairs(options.limits) do
    if retrying_from_failure and limit.type == "transfer" then
      -- don't reset it
    else
      limit.items = {}
    end
  end
  local slots = {}
  for _,p in ipairs(peripherals) do
    local l, cannot_wrap, must_wrap, after_action_bool = chest_list(p)
    if l ~= nil then
      local from_priority = glob(from,p)
      local to_priority = glob(to,p)
      for i=1,chest_size(p) do
        local slot = {}
        slot.chest_name = p
        slot.slot_number = i
        slot.is_source = false
        slot.is_dest = false
        slot.cannot_wrap = cannot_wrap
        slot.must_wrap = must_wrap
        slot.after_action = after_action_bool
        slot.from_priority = from_priority
        slot.to_priority = to_priority
        if l[i] == nil then
          slot.name = nil
          slot.nbt = nil
          slot.count = 0
          slot.limit = 1/0
        else
          slot.name = l[i].name
          slot.nbt = l[i].nbt
          slot.count = l[i].count
          slot.limit = l[i].limit
        end
        table.insert(slots,slot)
      end
    end
  end

  set_hoppering_stage("mark")
  mark_sources(slots,from)
  mark_dests(slots,to)

  glob_memoize = {}

  unmark_overlap_slots(slots)
  for _,slot in ipairs(slots) do
    for _,limit in ipairs(options.limits) do
      inform_limit_of_slot(limit, slot)
    end
  end

  local sources = {}
  local dests = {}
  local found_dests = false
  local found_sources = false
  for _,s in pairs(slots) do
    if s.is_source then
      found_sources = true
      if s.count > (s.voided or 0) then
        table.insert(sources,s)
      end
    elseif s.is_dest then
      found_dests = true
      if s.limit > s.count then
        table.insert(dests,s)
      end
    end
  end

  if not found_dests or not found_sources then
    if not found_sources then
      if not found_dests then
        latest_warning = "Warning: No sources nor destinations found."
      else
        latest_warning = "Warning: No sources found.                 "
      end
    else
      latest_warning   = "Warning: No destinations found.            "
    end
    options = nil
    filters = nil
    hoppering_stage = nil
    return
  end

  set_hoppering_stage("sort")
  sort_sources(sources)
  sort_dests(dests)
  turtle_lock()

  -- TODO: implement O(n) algo from TIL into here
  -- this is probably impossible at this point, though.
  hoppering_stage = "transfer"
  for si,s in ipairs(sources) do
    if s.name ~= nil and matches_filters(s) then
      local sw = willing_to_give(s)
      for di,d in ipairs(dests) do
        if sw == 0 then
          break
        end
        if not options.preserve_slots or s.slot_number == d.slot_number then
          if d.name == nil or (s.name == d.name and (s.nbt or "") == (d.nbt or "")) then
            local dw = willing_to_take(d,s)
            local to_transfer = math.min(sw,dw)
            to_transfer = to_transfer - (to_transfer % (options.batch_multiple or 1))
            if to_transfer < (options.min_batch or 0) then
              to_transfer = 0
            end
            if to_transfer > 0 then
              --FIXME: propagate errors up correctly
              --local success,transferred = pcall(transfer,s,d,to_transfer)
              local success = true
              local transferred = transfer(s,d,to_transfer)
              if not success or transferred ~= to_transfer then
                -- something went wrong, should we retry?
                local should_retry = true
                if isUPW(d.chest_name) then
                  -- the UPW api doesn't give us any indication of how many items an inventory can take
                  -- therefore the only way to transfer items is to just try and see if it succeeds
                  -- thus, failure is expected.
                  should_retry = false
                elseif isMEBridge(s.chest_name) then
                  -- the AdvancedPeripherals api doesn't give us maxCount
                  -- so this error is part of normal operation
                  should_retry = false
                elseif peripheral.wrap(d.chest_name).tanks then
                  -- fluid api doesn't give us inventory size either.
                  should_retry = false
                end
                -- FIXME: is implicitly retrying ever a good thing to do?
                -- ANSWER: it isn't.
                if should_retry then
                  if not success then
                    -- latest_error = "transfer() failed, retrying"
                    latest_warning = "WARNING: transfer() failed"
                  else
                    -- latest_error = "transferred too little, retrying"
                    latest_warning = "WARNING: transferred less than expected: "..s.chest_name..":"..s.slot_number.." -> "..d.chest_name..":"..d.slot_number
                  end
                  if not success then
                    transferred = 0
                  end
                  -- total_transferred = total_transferred + transferred
                  -- hoppering_stage = nil
                  -- return hopper_step(from,to,true)
                end
              end
              s.count = s.count - transferred
              d.count = d.count + transferred
              -- relevant if d was empty
              if transferred > 0 then
                d.name = s.name
                d.nbt = s.nbt
                --d.limit = s.limit
                if d.after_action then
                  after_action(d, s, transferred, dests, di)
                end
              end
              -- relevant if s became empty
              if s.count == 0 then
                s.name = nil
                s.nbt = nil
                s.limit = 1/0
              end

              report_transfer(transferred)
              for _,limit in ipairs(options.limits) do
                inform_limit_of_transfer(limit,s,d,transferred)
              end

              sw = willing_to_give(s)
            end
          end
        end
      end
    end
  end

  turtle_unlock()
  set_hoppering_stage(nil)
end

-- returns list of storage objects and peripheral blacklist
local function create_storage_objects(storage_options)
  local peripherals = peripheral.getNames()

  for _,o in pairs(storage_options) do
    local chests = {}
    for i,c in pairs(peripherals) do
      if glob(o.pattern, c) and not peripheral_blacklist[c] then
        table.insert(chests,c)
        peripheral_blacklist[c] = true
        peripherals[i] = nil
      end
    end
    local storage = til.new(chests)
    storages[o.name] = storage
  end
end

local function hopper_loop(commands,options)

  create_storage_objects(options.storages)

  local time_to_wake = nil
  while true do
    for _,command in ipairs(commands) do
      local from = command.from
      local to = command.to
      if not from then
        error("NO 'FROM' PARAMETER SUPPLIED")
      end
      if not to then
        error ("NO 'TO' PARAMETER SUPPLIED ('from' is "..from..")")
      end


      while coroutine_lock do coroutine.yield() end

      -- multiple hoppers running in parallel
      -- but within the same lua script can clash horribly
      coroutine_lock = true

      local provisions = {
        options=command.options,
        filters=command.filters,
        chest_wrap_cache={},
        self=determine_self(),
      }
      local success, error_msg = provide(provisions, function()
        return pcall(hopper_step,command.from,command.to)
      end)
      --hopper_step(command.from,command.to,peripherals,command.filters,command.options)

      coroutine_lock = false

      if not success then
        latest_error = error_msg
        if options.once then
          error(error_msg,0)
        end
      else
        latest_error = latest_warning
      end
    end

    if options.once then
      break
    end

    local current_time = os.epoch("utc")/1000
    time_to_wake = (time_to_wake or current_time) + options.sleep

    sleep(time_to_wake - current_time)
  end
end



local function hopper_parser_singular(args,is_lua)
  local from = nil
  local to = nil
  local options = {
    quiet=is_lua,
    once=is_lua,
    sleep=1,
  }
  options.limits = {}
  options.storages = {}
  options.denySlotless = nil -- UPW and MEBridge cannot work with some of the flags here

  local filters = {}
  local i=1
  while i <= #args do
    if glob("-*",args[i]) then
      if args[i] == "-once" then
        options.once = true
      elseif args[i] == "-forever" then
        options.once = false
      elseif args[i] == "-quiet" then
        options.quiet = true
      elseif args[i] == "-verbose" then
        if is_lua then
          error("cannot use -verbose through the lua api")
        end
        options.quiet = false
      elseif args[i] == "-debug" then
        options.debug = true
      elseif args[i] == "-negate" or args[i] == "-negated" or args[i] == "-not" then
        options.negate = true
      elseif args[i] == "-nbt" then
        -- this should only deny UPW
        -- but nbt hashes are currently unimpemented for ME bridge
        -- FIXME: implement nbt hashes for ME bridge and then change this and other relevant flags
        options.denySlotless = options.denySlotless or args[i]
        i = i+1
        filters[#filters].nbt = args[i]
      elseif args[i] == "-from_slot" then
        options.denySlotless = options.denySlotless or args[i]
        i = i+1
        if options.from_slot == nil then
          options.from_slot = {}
        end
        table.insert(options.from_slot,tonumber(args[i]))
      elseif args[i] == "-from_slot_range" then
        options.denySlotless = options.denySlotless or args[i]
        i = i+2
        if options.from_slot == nil then
          options.from_slot = {}
        end
        table.insert(options.from_slot,{tonumber(args[i-1]),tonumber(args[i])})
      elseif args[i] == "-to_slot" then
        options.denySlotless = options.denySlotless or args[i]
        i = i+1
        if options.to_slot == nil then
          options.to_slot = {}
        end
        table.insert(options.to_slot,tonumber(args[i]))
      elseif args[i] == "-to_slot_range" then
        options.denySlotless = options.denySlotless or args[i]
        i = i+2
        if options.to_slot == nil then
          options.to_slot = {}
        end
        table.insert(options.to_slot,{tonumber(args[i-1]),tonumber(args[i])})
      elseif args[i] == "-preserve_slots" or args[i] == "-preserve_order" then
        options.denySlotless = options.denySlotless or args[i]
        options.preserve_slots = true
      elseif args[i] == "-min_batch" or args[i] == "-batch_min" then
        i = i+1
        options.min_batch = tonumber(args[i])
      elseif args[i] == "-max_batch" or args[i] == "-batch_max" then
        i = i+1
        table.insert(options.limits, { type="transfer", limit=tonumber(args[i]) } )
        options.limits[#options.limits].per_slot = true
        options.limits[#options.limits].per_chest = true
      elseif args[i] == "-batch_multiple" then
        i = i+1
        options.batch_multiple = tonumber(args[i])
      elseif args[i] == "-from_limit_min" or args[i] == "-from_limit" then
        i = i+1
        table.insert(options.limits, { type="from", dir="min", limit=tonumber(args[i]) } )
      elseif args[i] == "-from_limit_max" then
        i = i+1
        table.insert(options.limits, { type="from", dir="max", limit=tonumber(args[i]) } )
      elseif args[i] == "-to_limit_min" then
        i = i+1
        table.insert(options.limits, { type="to", dir="min", limit=tonumber(args[i]) } )
      elseif args[i] == "-to_limit_max" or args[i] == "-to_limit" then
        i = i+1
        table.insert(options.limits, { type="to", dir="max", limit=tonumber(args[i]) } )
      elseif args[i] == "-refill" then
        table.insert(options.limits, { type="to", dir="min", limit=1 } )
        options.limits[#options.limits].per_name = true
        options.limits[#options.limits].per_chest = true
      elseif args[i] == "-transfer_limit" then
        i = i+1
        table.insert(options.limits, { type="transfer", limit=tonumber(args[i]) } )
      elseif args[i] == "-per_slot" then
        options.denySlotless = options.denySlotless or args[i]
        options.limits[#options.limits].per_slot = true
        options.limits[#options.limits].per_chest = true
      elseif args[i] == "-per_chest" then
        options.limits[#options.limits].per_chest = true
      elseif args[i] == "-per_slot_number" then
        options.denySlotless = options.denySlotless or args[i]
        options.limits[#options.limits].per_slot = true
      elseif args[i] == "-per_item" then
        options.limits[#options.limits].per_name = true
      elseif args[i] == "-per_nbt" then
        options.denySlotless = options.denySlotless or args[i]
        options.limits[#options.limits].per_name = true
        options.limits[#options.limits].per_nbt = true
      elseif args[i] == "-count_all" then
        options.limits[#options.limits].count_all = true
      elseif args[i] == "-alias" then
        i = i+2
        if not is_valid_name(args[i-1]) then
          error("Invalid name for -alias: "..args[i-1])
        end
        register_alias({name=args[i-1],pattern=args[i]})
      elseif args[i] == "-storage" then
        i = i+2
        if not is_valid_name(args[i-1]) then
          error("Invalid name for -storage: "..args[i-1])
        end
        table.insert(options.storages,{name=args[i-1], pattern=args[i]})
      elseif args[i] == "-sleep" then
        i = i+1
        options.sleep = tonumber(args[i])
      elseif args[i] == "-ender" then
        options.ender = true
      else
        error("UNKNOWN ARGUMENT: "..args[i])
      end
    else
      if not from then
        from = args[i]
      elseif not to then
        to = args[i]
      else
        table.insert(filters, {name=args[i]})
      end
    end

    i = i+1
  end

  return from,to,filters,options
end

-- returns: {from,to,filters,options}[], options
local function hopper_parser(args,is_lua)
  table.insert(args,"/") -- end the last command with `/`, otherwise it might get missed
  local global_options
  local commands = {}
  local token_list = {}
  for _,token in ipairs(args) do
    -- TODO: comments on `//`
    -- will probably involve better parsing
    if token == "/" then
      if #token_list > 0 then
        -- end of command, parse it and start a new one
        local from,to,filters,options = hopper_parser_singular(token_list,is_lua)
        if from then
          table.insert(commands,{from=from,to=to,filters=filters,options=options})
        end
        if not global_options then
          global_options = options
        end

        token_list = {}
      end
    else 
      -- insert token into token_list for parsing
      table.insert(token_list, token)
    end
  end
  args[#args] = nil -- remove the `/` we added earlier
  return commands, global_options
end

local function hopper_main(args, is_lua, just_listing)
  local commands,options = hopper_parser(args,is_lua)
  local args_string = table.concat(args," ")
  local hoppering_stage = nil
  local total_transferred = 0
  local provisions = {
    is_lua = is_lua,
    just_listing = just_listing,
    get_hoppering_stage = function() return hoppering_stage end,
    set_hoppering_stage = function(stage)
      hoppering_stage = stage
    end,
    report_transfer = function(transferred)
      total_transferred = total_transferred + transferred
      return total_transferred
    end,
    start_time = options.quiet or os.epoch("utc"),
  }
  local function displaying()
    provide(provisions, function()
      display_loop(options,args_string)
    end, true)
  end
  local function transferring()
    provide(provisions, function()
      hopper_loop(commands,options)
    end, true)
  end
  exitOnTerminate(function() 
    -- provisions don't work through waitForAny
    -- because waitForAny swallows the yields
    -- and then yields without a filter
    parallel.waitForAny(transferring, displaying)
  end)
  provide(provisions, function()
    display_exit(options,args_string)
  end, true)
  return total_transferred
end

local function hopper_list(args_string)
  local args = {}
  for arg in args_string:gmatch("%S+") do 
    table.insert(args, arg)
  end

  return hopper_main(args, true, true)
end

local function hopper(args_string)
  local args = {}
  for arg in args_string:gmatch("%S+") do 
    table.insert(args, arg)
  end

  return hopper_main(args, true)
end

local function isImported(args)
  if #args == 2 and type(package.loaded[args[1]]) == "table" and not next(package.loaded[args[1]]) then
    return true
  else
    return false
  end
end

local function main(args)
  local is_imported = isImported(args)
  -- this nonsense is here to handle newlines
  -- it might be better to just hand hopper_main() the joint string, though.
  local args_string = table.concat(args, " ")
  args = {}
  for arg in args_string:gmatch("%S+") do
    table.insert(args, arg)
  end

  if is_imported then
    local exports = {
      hopper=hopper,
      version=version,
      storages=storages,
    }
    setmetatable(exports,{
      _G=_G,
      __call=function(self, args) return hopper(args) end
    })
    return exports
  end

  if #args < 2 then
      print(help_message)
      return
  end

  hopper_main(args)
end



til = load([==[ -- Copyright umnikos (Alex Stefanov) 2024
-- Licensed under MIT license
local version = "0.13"

-- defined at the end
local exports

-- cache of stack sizes, name -> number
local stack_sizes = {}

local function splitIdent(ident)
  local i = string.find(ident,";")
  local nbt = string.sub(ident,i+1)
  local name = string.sub(ident,0,i-1)
  return name,nbt
end

-- returns a list of {name,nbt,count}
local function list(inv)
  local l = {}
  for k,v in pairs(inv.items) do
    local name,nbt = splitIdent(k)
    local count = v.count
    table.insert(l,{name=name,nbt=nbt,count=count})
  end
  return l
end

-- inform the storage of the stack size of an item it has not seen yet
-- DO NOT LIE! (even if it's convenient)
local function informStackSize(name,stacksize)
  stack_sizes[name] = stacksize
end

local function getStackSize(name)
  return stack_sizes[name]
end

-- additional amounts of that item the storage is able to store
local function spaceFor(inv,name,nbt)
  -- partial slots
  local stacksize = stack_sizes[name]
  if not stacksize then
    return nil
  end
  local ident = name..";"..(nbt or "")
  local partials = inv.items[ident] or {slots={},count=0}
  local partial_slot_space = (#partials.slots)*stacksize - partials.count
  local empty_slot_space = (#inv.empty_slots)*stacksize

  return partial_slot_space + empty_slot_space
end

-- amount of a particular item in storage
local function amountOf(inv,name,nbt)
  local ident = name..";"..(nbt or "")
  if not inv.items[ident] then
    return 0
  end
  return inv.items[ident].count
end

-- transfer from one storage to another
local function transfer(inv1,inv2,name,nbt,amount)
  local stacksize = stack_sizes[name]
  if not stacksize then
    error("Unknown stack size?!?")
  end

  local ident = name..";"..(nbt or "")
  inv1.items[ident] = inv1.items[ident] or {count=0,slots={},first_partial=1}
  inv2.items[ident] = inv2.items[ident] or {count=0,slots={},first_partial=1}
  local sources = inv1.items[ident].slots
  local sl = #sources
  local dests_partial = inv2.items[ident].slots
  local dlp = #dests_partial
  local dests_empty = inv2.empty_slots
  local dle = #dests_empty

  local si = sl
  local di = inv2.items[ident].first_partial
  local transferred = 0
  local s
  local d
  while amount > 0 and si >= 1 and di <= (dlp+dle) do
    if not s then
      s = sources[si]
    end
    if not d then
      if di <= dlp then 
        d = dests_partial[di]
      else
        d = dests_empty[dle-(di-dlp)+1]
      end
    end

    if not s or s.count <= 0 then
      si = si - 1
      s = nil
    elseif not d or d.count >= stacksize then
      di = di + 1
      d = nil
    else
      local to_transfer = math.min(amount, s.count, stacksize-d.count)
      local real_transfer = peripheral.wrap(s.chest).pushItems(d.chest,s.slot,to_transfer,d.slot)
      -- we will work with the real transfer amount
      -- if it doesn't match the planned amount we'll error *after* updating everything
      -- because if only one of the storages is inconsistent we want to maintain consistency on the other one

      transferred = transferred + real_transfer
      amount = amount - real_transfer
      s.count = s.count - real_transfer
      inv1.items[ident].count = inv1.items[ident].count - real_transfer
      if s.count == 0 then
        -- source is an empty slot now
        table.insert(inv1.empty_slots,s)
        inv1.items[ident].slots[si] = nil
      end
      if s.count < stacksize then
        -- source is not a full slot now
        inv1.items[ident].first_partial = si
      end

      d.count = d.count + real_transfer
      if di <= dlp then
        if d.count >= stacksize then
          -- dest is a full slot now
          inv2.items[ident].first_partial = di+1
        end
      else
        if d.count > 0 then
          -- dest is not an empty slot now
          table.insert(inv2.items[ident].slots,d)
          inv2.empty_slots[dle-(di-dlp)+1] = nil
        end
      end
      inv2.items[ident].count = inv2.items[ident].count + real_transfer

      if to_transfer ~= real_transfer then
        error("Inconsistency detected during til transfer")
      end
    end
  end
  return transferred
end

-- transfer from a chest
-- from_slot is a required argument (might change in the future)
-- to_slot does not exist as an argument, if passed it'll simply be ignored
-- list_cache is optionally a .list() of the source chest
local function pullItems(inv,chest,from_slot,amount,_to_slot,list_cache)
  if type(from_slot) ~= "number" then
    error("from_slot is a required argument")
  end
  local l = list_cache or peripheral.wrap(chest.list)
  local s = l[from_slot]
  local inv2 = exports.new({chest},1,{[chest]=l},from_slot)
  return inv2.transfer(inv,s.name,s.nbt,amount)
end

-- transfer to a chest
-- from_slot is a required argument, and determines the type of item transferred
-- if from_slot is a number it will transfer the type of item at that entry in inv.list()
-- if from_slot is a "name;nbt" string then it'll transfer that type of item
-- list_cache is optionally a .list() of the destination chest
local function pushItems(inv,chest,from_slot,amount,to_slot,list_cache)
  local name,nbt
  if type(from_slot) == "number" then
    local l = inv.list()
    if l[from_slot] then
      name = l[from_slot].name
      nbt = l[from_slot].nbt
    end
  elseif type(from_slot) == "string" then
    name,nbt = splitIdent(from_slot)
  end
  if not name then
    error("item name is nil")
  end
  if not nbt then nbt = "" end
  local inv2 = exports.new({chest},1,{[chest]=list_cache},to_slot)
  return inv.transfer(inv2,name,nbt,amount)
end


local function addInvMethods(inv)
  -- add methods to the inv
  inv.informStackSize = informStackSize
  inv.getStackSize = getStackSize
  inv.spaceFor = function(name,nbt) return spaceFor(inv,name,nbt) end
  inv.amountOf = function(name,nbt) return amountOf(inv,name,nbt) end
  inv.transfer = function(inv2,name,nbt,amount) return transfer(inv,inv2,name,nbt,amount) end
  inv.pushItems = function(chest,from_slot,amount,to_slot,list_cache) return pushItems(inv,chest,from_slot,amount,to_slot,list_cache) end
  inv.pullItems = function(chest,from_slot,amount,_to_slot,list_cache) return pullItems(inv,chest,from_slot,amount,_to_slot,list_cache) end
  inv.list = function() return list(inv) end
end

-- combine two storages into one new storage that has the slots of both original storages
-- this function may behave incorrectly if the two storages share slots with each other
local function mergeStorages(invs)
  local inv = {}
  inv.items = {}
  inv.empty_slots = {}
  for _,invn in pairs(invs) do
    for _,empty_slot in pairs(invn.empty_slots) do
      table.insert(inv.empty_slots,empty_slot)
    end
    for ident,items in pairs(invn.items) do
      inv.items[ident] = inv.items[ident] or {count=0,slots={},first_partial=1}
      inv.items[ident].count = inv.items[ident].count + items.count
      -- we can just ignore first_partial, a further transfer operation will fix it for us
      for _,slot in pairs(items.slots) do
        table.insert(inv.items[ident].slots,slot)
      end
    end
  end

  addInvMethods(inv)
  return inv
end

-- create an inv object out of a list of chests
local function new(chests, indexer_threads,list_cache,slot_number)
  if not list_cache then list_cache = {} end
  indexer_threads = math.min(indexer_threads or 32, #chests)

  local inv = {}
  -- name;nbt -> total item count + list of slots with counts
  inv.items = {}
  -- list of empty slots
  inv.empty_slots = {}

  do -- index chests
    local chestsClone = {}
    for _,v in ipairs(chests) do
      chestsClone[#chestsClone+1] = v
    end

    local function indexerThread()
      while true do
        if #chestsClone == 0 then return end
        local cname = chestsClone[#chestsClone]
        chestsClone[#chestsClone] = nil

        local c = peripheral.wrap(cname)
        -- 1.12 cc + plethora calls getItemDetail "getItemMeta"
        if not c.getItemDetail then
          c.getItemDetail = c.getItemMeta
        end

        local l = list_cache[cname] or c.list()
        local size = slot_number or c.size()
        for i = (slot_number or 1),size do
          local item = l[i]
          if not item or not item.name then
            -- empty slot
            table.insert(inv.empty_slots,{count=0,chest=cname,slot=i})
          else
            -- slot with an item
            local nbt = item.nbt or ""
            local name = item.name
            local count = item.count
            local ident = name..";"..nbt -- identifier
            inv.items[ident] = inv.items[ident] or {count=0,slots={},first_partial=1}
            inv.items[ident].count = inv.items[ident].count + count
            table.insert(inv.items[ident].slots,{count=count,chest=cname,slot=i})

            -- inform stack sizes cache if it doesn't know this item
            -- this is slow but it's only done once per item type
            if not stack_sizes[name] then
              stack_sizes[name] = c.getItemDetail(i).maxCount
            end
          end
        end
      end
    end

    local threads = {}
    for i=1, indexer_threads do
      threads[#threads+1] = indexerThread
    end

    parallel.waitForAll(table.unpack(threads))
  end

  addInvMethods(inv)
  return inv
end




exports = {
  version=version,
  new=new,
  mergeStorages=mergeStorages
}

return exports
 ]==])()
return main({...})