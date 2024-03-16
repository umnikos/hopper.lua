-- Copyright umnikos (Alex Stefanov) 2023
-- Licensed under MIT license
local version = "v1.3.2"

local help_message = [[
hopper script ]]..version..[[, made by umnikos

example usage: 
  hopper *chest* *barrel* *:pink_wool -negate

for more info check out the repo:
  https://github.com/umnikos/hopper.lua]]

-- v1.3.2 changelog:
-- refactoring
-- fix sleep() logic
-- turtles no longer need a modem to hopper between self and self/void
-- attempt to find modems on the left/right of a turtle as well (will still fail if that side has a module)
-- 'or' pattern priority now takes priority over all other priorities
-- -count_all now applies to a specific limit instead of being global
-- preserve which slot was used initially before a self->self transfer
-- fix crash when running multiple hopper.lua instances through the lua interface
-- just refuse to crash if running in a loop (but still display the error on the screen)
-- -min_batch (or -batch_min) to set the smallest allowed transfer size
-- shows current command and uptime while running

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
local function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

local function glob(ps, s)
  local i = 0
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
local function save_cursor()
  cursor_x,cursor_y = term.getCursorPos()
end
local function go_back(n)
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
  if options.limits == nil then
    options.limits = {}
  end
  if type(options.from_slot) == number then
    options.from_slot = {options.from_slot}
  end
  if type(options.to_slot) == number then
    options.to_slot = {options.to_slot}
  end
  return options
end

local filters -- global filters during hopper step

local function default_filters(filters)
  if not filters then
    filters = {}
  end
  if type(filters) == "string" then
    filters = {filters}
  end
  return filters
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

local total_transferred = 0
local hoppering_stage = nil
local start_time
local function display_exit(from, to, filters, options, args_string)
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
  print("total uptime: "..format_time(elapsed_time))
  print("transferred total: "..total_transferred.." ("..ips_rounded.." i/s)    ")
end

local latest_error = nil
local function display_loop(from, to, filters, options, args_string)
  if options.quiet then 
    halt()
  end
  term.clear()
  go_back()
  print("hopper.lua "..version)
  print("$ hopper "..args_string)
  print("")
  save_cursor()

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
      print((hoppering_stage or "idle").."      ")
    end
    print("uptime: "..format_time(elapsed_time).."    ")
    if latest_error then
      term.clearLine()
      print("")
      print(latest_error)
    else
      term.write("transferred so far: "..total_transferred.." ("..ips_rounded.." i/s)    ")
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
  local c = peripheral.wrap(chest)
  if not c then
    --error("failed to wrap "..chest_name)
    return no_c, cannot_wrap, must_wrap, after_action
  end
  if c.ejectDisk then
    c.ejectDisk()
    cannot_wrap = true
    after_action = true
    c.list = function() return {} end
    c.size = function() return 1 end
    return c, cannot_wrap, must_wrap, after_action
  end
  if c.getInventory then
    -- this is actually a bound introspection module
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
  if not c.list then
    -- failed to wrap it for some reason
    return no_c, cannot_wrap, must_wrap, after_action
  end
  local cc = {
    list= function()
      local l = c.list()
      for i,item in pairs(l) do
        if limits_cache[item.name] == nil then
          local details = c.getItemDetail(i)
          l[i] = details
          if details ~= nil then
            limits_cache[details.name] = details.maxCount
          end
        end
        if l[i] then
          l[i].limit = limits_cache[item.name]
        end
      end
      return l
    end,
    size=c.size,
    pullItems=c.pullItems,
    pushItems=c.pushItems,
  }
  return cc, cannot_wrap, must_wrap, after_action
end

local function chest_list(chest)
  local c, cannot_wrap, must_wrap, after_action = chest_wrap(chest)
  return c.list(), cannot_wrap, must_wrap, after_action
end

local function chest_size(chest)
  local c = chest_wrap(chest)
  return c.size()
end

local function transfer(from_slot,to_slot,count)
  if count <= 0 then
    return 0
  end
  if from_slot.chest_name == nil or to_slot.chest_name == nil then
    error("NIL CHEST")
  end
  if (not from_slot.cannot_wrap) and (not to_slot.must_wrap) then
    local other_peripheral = to_slot.chest_name
    if other_peripheral == "self" then other_peripheral = self end
    local c = chest_wrap(from_slot.chest_name)
    if not c then
      return 0
    end
    return c.pushItems(other_peripheral,from_slot.slot_number,count,to_slot.slot_number)
  end
  if (not to_slot.cannot_wrap) and (not from_slot.must_wrap) then
    local other_peripheral = from_slot.chest_name
    if other_peripheral == "self" then other_peripheral = self end
    local c = chest_wrap(to_slot.chest_name)
    if not c then
      return 0
    end
    return c.pullItems(other_peripheral,from_slot.slot_number,count,to_slot.slot_number)
  end
  if to_slot.chest_name == "void" then
    -- the void consumes all that you give it
    return count
  end
  if from_slot.chest_name == "self" and to_slot.chest_name == "self" then
    self_save_slot()
    turtle.select(from_slot.slot_number)
    -- this bs doesn't return how many items were moved
    turtle.transferTo(to_slot.slot_number,count)
    -- so we'll just trust that the math we used to get `count` is correct
    return count
  end
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
    error("bruh")
  end
  local identifier = ""
  if limit.per_chest then
    identifier = identifier..slot.chest_name
  end
  identifier = identifier..";"
  if limit.per_slot then
    if slot.chest_name ~= "void" then
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
  local from_identifier = limit_slot_identifier(limit,from)
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
    error("UNKNOWN LIMT TYPE "..limit.type)
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
  local allowance = slot.limit - slot.count
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

local function after_action(d,s)
  if d.chest_name == "void" then
    s.count = s.count + d.count
    s.voided = (s.voided or 0) + d.count
    d.count = 0
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

local function hopper_step(from,to,peripherals,my_filters,my_options,retrying_from_failure)
  -- multiple hoppers running in parallel
  -- but within the same lua script can clash horribly


  filters = my_filters
  options = my_options

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
    local l, cannot_wrap, must_wrap, after_action = chest_list(p)
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
        slot.after_action = after_action
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
  for _,s in pairs(slots) do
    if s.is_source then
      if s.count > (s.voided or 0) then
        table.insert(sources,s)
      end
    elseif s.is_dest then
      if s.limit > s.count then
        table.insert(dests,s)
      end
    end
  end

  if #sources == 0 or #dests == 0 then
    options = nil
    filters = nil
    hoppering_stage = nil
    return
  end

  hoppering_stage = "sort"
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

  hoppering_stage = "transfer"
  for si,s in pairs(sources) do
    if s.name ~= nil and matches_filters(filters,s,options) then
      local sw = willing_to_give(s,options)
      for di,d in pairs(dests) do
        if sw == 0 then
          break
        end
        if d.name == nil or (s.name == d.name and s.nbt == d.nbt) then
          local dw = willing_to_take(d,options,s)
          local to_transfer = math.min(sw,dw)
          if to_transfer < (options.min_batch or 0) then
            to_transfer = 0
          end
          if to_transfer > 0 then
            local success,transferred = pcall(transfer,s,d,to_transfer)
            if not success or transferred ~= to_transfer then
              -- something went wrong, rescan and try again
              if not success then
                transferred = 0
              end
              total_transferred = total_transferred + transferred
              hoppering_stage = nil
              return hopper_step(from,to,peripherals,my_filters,my_options,true)
            end
            s.count = s.count - transferred
            d.count = d.count + transferred
            -- relevant if d was empty
            d.name = s.name
            d.nbt = s.nbt
            d.limit = s.limit
            if d.after_action then
              after_action(d, s)
            end
            -- relevant if d became empty
            if d.count == 0 then
              d.name = nil
              d.nbt = nil
              d.limit = 1/0
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

  self_restore_slot()
  options = nil
  filters = nil
  hoppering_stage = nil
end

local function hopper_loop(from,to,filters,options)
  options = default_options(options)
  filters = default_filters(filters)

  local time_to_wake = nil
  while true do
    determine_self()
    local peripherals = {}
    table.insert(peripherals,"void")
    if self then
      table.insert(peripherals,"self")
    end
    for _,p in ipairs(peripheral.getNames()) do
      if glob(from,p) or glob(to,p) then
        table.insert(peripherals,p)
      end
    end

    local old_total = total_transferred

    while coroutine_lock do coroutine.yield() end
    coroutine_lock = true
    local success, error_msg = pcall(hopper_step,from,to,peripherals,filters,options)
    coroutine_lock = false

    if options.once then
      if not success then
        error(error_msg)
      end
      break
    end

    if not success then
      latest_error = error_msg
    else
      latest_error = nil
    end

    local current_time = os.epoch("utc")/1000
    time_to_wake = (time_to_wake or current_time) + options.sleep

    sleep(time_to_wake - current_time)
  end
end



local function hopper_parser(args)
  local from = args[1]
  local to = args[2]
  local options = {}
  options.limits = {}

  local filters = {}
  local i=3
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
        i = i+1
        filters[#filters].nbt = args[i]
      elseif args[i] == "-from_slot" then
        i = i+1
        if options.from_slot == nil then
          options.from_slot = {}
        end
        table.insert(options.from_slot,tonumber(args[i]))
      elseif args[i] == "-from_slot_range" then
        i = i+2
        if options.from_slot == nil then
          options.from_slot = {}
        end
        table.insert(options.from_slot,{tonumber(args[i-1]),tonumber(args[i])})
      elseif args[i] == "-to_slot" then
        i = i+1
        if options.to_slot == nil then
          options.to_slot = {}
        end
        table.insert(options.to_slot,tonumber(args[i]))
      elseif args[i] == "-to_slot_range" then
        i = i+2
        if options.to_slot == nil then
          options.to_slot = {}
        end
        table.insert(options.to_slot,{tonumber(args[i-1]),tonumber(args[i])})
      elseif args[i] == "-min_batch" or args[i] == "-batch_min" then
        i = i+1
        options.min_batch = tonumber(args[i])
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
        options.limits[#options.limits].per_slot = true
        options.limits[#options.limits].per_chest = true
      elseif args[i] == "-per_chest" then
        options.limits[#options.limits].per_chest = true
      elseif args[i] == "-per_slot_number" then
        options.limits[#options.limits].per_slot = true
      elseif args[i] == "-per_item" then
        options.limits[#options.limits].per_name = true
      elseif args[i] == "-per_nbt" then
        options.limits[#options.limits].per_name = true
        options.limits[#options.limits].per_nbt = true
      elseif args[i] == "-count_all" then
        options.limits[#options.limits].count_all = true
      elseif args[i] == "-sleep" then
        i = i+1
        options.sleep = tonumber(args[i])
      elseif args[i] == "-ender" then
        options.ender = true
      else
        error("UNKNOWN ARGUMENT: "..args[i])
        return
      end
    else
      table.insert(filters, {name=args[i]})
    end

    i = i+1
  end

  return from,to,filters,options
end

local function hopper_main(args, is_lua)
  local from,to,filters,options = hopper_parser(args)
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
    display_loop(from,to,filters,options,args_string)
  end
  local function transferring()
    hopper_loop(from,to,filters,options)
  end
  total_transferred = 0
  exitOnTerminate(function() 
    parallel.waitForAny(transferring, displaying)
  end)
  display_exit(from,to,filters,options,args_string)
  return total_transferred
end

local function hopper(args_string)
  local args = {}
  for arg in args_string:gmatch("%S+") do 
    table.insert(args, arg)
  end

  return hopper_main(args, true)
end

local function main(args)
  if args[1] == "hopper" then
    local exports = {
      hopper=hopper,
      version=version
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

local args = {...}

return main(args)
