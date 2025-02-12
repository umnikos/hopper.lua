-- Copyright umnikos (Alex Stefanov) 2023-2025
-- Licensed under MIT license
local version = "v1.4.1"

local til

local help_message = [[
hopper script ]]..version..[[, made by umnikos

example usage: 
  hopper *chest* *barrel* *:pink_wool -negate

for more info check out the repo:
  https://github.com/umnikos/hopper.lua]]

-- v1.4.1 changelog:
-- UnlimitedPeripheralWorks mod integrations:
-- - item transfer between UPW inventories (and UPW<->generic inv as well)
-- - fluid transfer between UPW inventories
-- - AE2 integration possible by connecting a wired modem to any energy cell in the AE2 network
-- AdvancedPeripherals mod integrations:
-- - ME bridge (connect the bridge to cc via a wired modem)
-- - item transfer (without -nbt)
-- show a warning on screen if there's currently 0 matching sources or destinations
-- fix incorrect imports detection on CC: Restitched

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

-- for debugging purposes
local pretty = require("cc.pretty")
local pprint = pretty.pretty_print

local aliases = {}
local function glob(ps, s)
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
      return true, i
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
  if options.debug then margin=2 else margin=1 end
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

local options -- global options during hopper step

local function default_options(options)
  if not options then
    options = {}
  end
  if options.quiet == nil then
    options.quiet = false
  end
  if options.once == nil then
    options.once = false
  end
  if options.sleep == nil then
    options.sleep = 1
  end
  return options
end

local filters -- global filters during hopper step

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

local total_transferred = 0
local hoppering_stage = nil
local start_time
local function display_exit(options, args_string)
  if options.quiet then
    return
  end
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
  term.clear()
  go_back()
  print("hopper.lua "..version)
  args_string = args_string:gsub(" / ","\n/ ")
  print("$ hopper "..args_string)
  print("")
  save_cursor(options)

  start_time = os.epoch("utc")
  local time_to_wake = start_time/1000
  while true do
    local elapsed_time = os.epoch("utc")-start_time
    local ips = (total_transferred*1000/elapsed_time)
    if ips ~= ips then
      ips = 0
    end
    local ips_rounded = math.floor(ips*100)/100
    go_back()
    if options.debug then
      print((hoppering_stage or "nilstate").."        ")
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
local self = nil
local function determine_self()
  if not turtle then return end
  for _,dir in ipairs({"top","front","bottom","back","right","left"}) do
    local p = peripheral.wrap(dir)
    if p and p.getNameLocal then
      self = p.getNameLocal()
      return
    end
  end
  -- could not find modem but it is a turtle, so here's a placeholder value
  self = "self"
end

-- if we used turtle.select() anywhere during transfer
-- move it back to the original slot
local self_original_slot
local function self_save_slot()
  if not self then return end
  -- only save if we haven't saved already
  -- this way we can just save before every turtle.select()
  if not self_original_slot then
    self_original_slot = turtle.getSelectedSlot()
  end
end
local function self_restore_slot()
  if not self then return end
  if self_original_slot then
    turtle.select(self_original_slot)
    self_original_slot = nil
  end
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
-- limit: how much of this item the slot can store, 64 for most items, 1 for unstackables
-- is_source: whether this slot matches source slot critera
-- is_dest: whether this slot matches dest slot criteria
-- cannot_wrap: the chest this slot is in cannot be wrapped
-- must_wrap: the chest this slot is in must be wrapped
-- after_action: identifies that some special action must be done after transferring to this slot
-- voided: how many of the items are physically there but are pretending to be missing
-- from_priority/to_priority: how early in the pattern match the chest appeared, lower number means higher priority

local function matches_filters(filters,slot,options)
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
local function chest_wrap(chest)
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
    if not c.items then
      -- forge
      c.items = c.list
      c.pushItem = c.pushItems
      c.pullItem = c.pullItems
      c.getItemDetailForge = c.getItemDetail
    end
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
    c.size = function()
      local s = 1+#c.list()
      return s
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
    if c.size then size = c.size() end
    if c.tanks then size = size + 1 + #c.tanks() end
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
  if count <= 0 then
    return 0
  end
  if from_slot.chest_name == nil or to_slot.chest_name == nil then
    error("NIL CHEST")
  end
  if item_types[from_slot.name] == "f" then
    -- fluids are to be dealt with here, separately.
    if not isMEBridge(from_slot.chest_name) and not isMEBridge(to_slot.chest_name) then
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
    if other_peripheral == "self" then other_peripheral = self end
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
    if other_peripheral == "self" then other_peripheral = self end
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
    -- FIXME: this is not the correct time to save the original slot
    -- it should be done before all the transfers, not before every transfer
    self_save_slot()
    turtle.select(from_slot.slot_number)
    -- this bs doesn't return how many items were moved
    turtle.transferTo(to_slot.slot_number,count)
    -- so we'll just trust that the math we used to get `count` is correct
    return count
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

local function mark_sources(slots,from,filters,options) 
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

local function mark_dests(slots,to,filters,options) 
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

local function unmark_overlap_slots(slots,options)
  for _,s in ipairs(slots) do
    if s.is_source and s.is_dest then
      -- TODO: option to choose how this gets resolved
      -- currently defaults to being dest
      s.is_source = false
    end
  end
end

local function limit_slot_identifier(limit,primary_slot,other_slot)
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
    if not matches_filters(filters,slot,options) then
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

local function inform_limit_of_slot(limit,slot,options)
  if slot.name == nil then return end
  if limit.type == "transfer" then return end
  if limit.type == "from" and (not slot.is_source) then return end
  if limit.type == "to" and (not slot.is_dest) then return end
  -- from and to limits follow
  local identifier = limit_slot_identifier(limit,slot)
  limit.items[identifier] = (limit.items[identifier] or 0) + slot.count
end

local function inform_limit_of_transfer(limit,from,to,amount,options)
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

local function willing_to_give(slot,options)
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

local function willing_to_take(slot,options,source_slot)
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
    allowance = slot.limit
  else
    -- real regular slot
    allowance = math.min(slot.limit,stack_size or (1/0)) - slot.count
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
local function hopper_step(from,to,peripherals,my_filters,my_options,retrying_from_failure)
  filters = my_filters
  options = my_options
  latest_warning = nil

  hoppering_stage = "scan"
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
      local _,from_priority = glob(from,p)
      local _,to_priority = glob(to,p)
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

  hoppering_stage = "mark"
  mark_sources(slots,from,filters,options)
  mark_dests(slots,to,filters,options)
  unmark_overlap_slots(slots,options)
  for _,slot in ipairs(slots) do
    for _,limit in ipairs(options.limits) do
      inform_limit_of_slot(limit, slot,options)
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

  hoppering_stage = "sort"
  sort_sources(sources)
  sort_dests(dests)

  -- TODO: implement O(n) algo from TIL into here
  hoppering_stage = "transfer"
  for si,s in pairs(sources) do
    if s.name ~= nil and matches_filters(filters,s,options) then
      local sw = willing_to_give(s,options)
      for di,d in pairs(dests) do
        if sw == 0 then
          break
        end
        if not options.preserve_slots or s.slot_number == d.slot_number then
          if d.name == nil or (s.name == d.name and (s.nbt or "") == (d.nbt or "")) then
            local dw = willing_to_take(d,options,s)
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
                if should_retry then
                  if not success then
                    latest_error = "transfer() failed, retrying"
                  else
                    latest_error = "transferred too little, retrying"
                  end
                  if not success then
                    transferred = 0
                  end
                  total_transferred = total_transferred + transferred
                  hoppering_stage = nil
                  return hopper_step(from,to,peripherals,my_filters,my_options,true)
                end
              end
              s.count = s.count - transferred
              d.count = d.count + transferred
              -- relevant if d was empty
              if transferred > 0 then
                d.name = s.name
                d.nbt = s.nbt
                d.limit = s.limit
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

              total_transferred = total_transferred + transferred
              for _,limit in ipairs(options.limits) do
                inform_limit_of_transfer(limit,s,d,transferred,options)
              end

              sw = willing_to_give(s,options)
            end
          end
        end
      end
    end
  end

  self_restore_slot()
  options = nil
  filters = nil
  hoppering_stage = nil
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
  options = default_options(options)

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

      determine_self()
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

      while coroutine_lock do coroutine.yield() end

      -- multiple hoppers running in parallel
      -- but within the same lua script can clash horribly
      coroutine_lock = true

      local success, error_msg = pcall(hopper_step,command.from,command.to,peripherals,command.filters,command.options)
      --hopper_step(command.from,command.to,peripherals,command.filters,command.options)

      coroutine_lock = false

      if not success then
        latest_error = error_msg
        if options.once then
          error(error_msg)
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



local function hopper_parser_singular(args)
  local from = nil
  local to = nil
  local options = {}
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
        table.insert(aliases,{name=args[i-1],pattern=args[i]})
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
local function hopper_parser(args)
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
        local from,to,filters,options = hopper_parser_singular(token_list)
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

local function hopper_main(args, is_lua)
  local commands,options = hopper_parser(args)
  if is_lua then
    if options.once == nil then
      options.once = true
    end
    if options.quiet == nil then
      options.quiet = true
    end
  end
  local args_string = table.concat(args," ")
  local function displaying()
    display_loop(options,args_string)
  end
  local function transferring()
    hopper_loop(commands,options)
  end
  total_transferred = 0
  exitOnTerminate(function() 
    parallel.waitForAny(transferring, displaying)
  end)
  display_exit(options,args_string)
  return total_transferred
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
      storages=storages
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


