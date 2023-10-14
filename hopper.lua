-- Copyright umnikos (Alex Stefanov) 2023
-- Licensed under MIT license
-- Version 1.3 ALPHA

local version = "v1.3 ALPHA23"
local help_message = [[
hopper script ]]..version..[[, made by umnikos

usage: 
  hopper {from} {to} [{item name}/{flag}]*
example: 
  hopper *chest* *barrel* *:pink_wool -negate

for a list of all valid flags
  view the source file]]

-- flags:
--  general:
--   -once : run the script only once instead of in a loop (undo with -forever)
--   -quiet: print less things to the terminal (undo with -verbose)
--   -negate: instead of transferring if any filter matches, transfer if no filters match
--   -nbt [nbt string]: change the filter just before this to match only items with this nbt
--   -sleep [num]: set the delay in seconds between each iteration (default is 1)]]
--  specifying slots:
--   -from_slot [slot]: restrict pulling to a single slot
--   -to_slot [slot]: restrict pushing to a single slot
--   -from_slot_range [num] [num]: restrict pulling to a slot range
--   -to_slot_range [num] [num]: restrict pushing to a slot range
--  specifying limits:
--   -from_limit [num]: keep at least this many matching items in every source chest
--   -to_limit [num]: fill every destination chest with at most this many matching items
--   -transfer_limit [num]: move at most this many items per iteration (useful for ratelimiting)
--   -per_chest: the limit count is kept separately for each chest
--   -per_slot: the limit count is kept separately for each slot in each chest
--   -per_item: the limit count is kept separately for each item name (regardless of nbt)
--   -per_nbt: the limit count is kept separately for each item and nbt
--   -count_all: count even non-matching items towards the limits (they won't be transferred)
-- further things of note:
--   `self` is a valid peripheral name if you're running the script from a turtle connected to a wired modem
--   you can import this file as a library with `require "hopper"` (alpha feature, subject to change)
--   the script will prioritize taking from almost empty stacks and filling into almost full stacks




-- TODO: parallelize inventory calls for super fast operations

-- TODO: `-refill` to only feed into slots/chests/whatever that already have at least one of the item (sort of like -to_minimum)
-- TODO: `/` for multiple hopper operations with the same scan (conveniently also implementing prioritization)
-- TODO: caching for inventories only hopper.lua has access to
-- TODO: conditional transfer (based on whether the previous command succeeded?)
  -- items can block each other, thus you can make a transfer happen only if that slot is free by passing items through said slot
-- TODO: some way to treat chests as queues
-- TODO: hopper water bottles into brewing stand only when it doesn't contain anything that's not water bottles
  -- multiplier for -to_limit?
-- TODO: multiple sources and destinations, with separate -to_slot and -from_slot flags

-- TODO: batch hoppering condition
  -- impossible to do robustly
-- TODO: some way to get information about the contents of the chests through the API

-- TODO: iptables-inspired item routing?

local function noop()
end

local print = print
local term = {
  getCursorPos = term.getCursorPos,
  setCursorPos = term.setCursorPos,
  write = term.write,
}

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

local function glob(p, s)
  p = string.gsub(p,"*",".*")
  p = string.gsub(p,"-","%%-")
  p = "^"..p.."$"
  local res = string.find(s,p)
  return res ~= nil
end

local function line_to_start()
  local x,y = term.getCursorPos()
  term.setCursorPos(1,y)
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
  --IDEA: to/from slot ranges instead of singular slots
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

local function display_info(from, to, filters, options)
  if options.quiet then 
    print = noop 
    term = {
      getCursorPos = term.getCursorPos,
      setCursorPos = noop,
      write = noop,
    }
  end
  print("hopper.lua "..version)
  print("")

  print("hoppering from "..from)
  if options.from_slot then
    print("and only from slot "..tostring(options.from_slot))
  end
  if options.from_limit then
    print("keeping at least "..tostring(options.from_limit).." items in reserve per container")
  end
  print("to "..to)
  if options.to_slot then
    print("and only to slot "..tostring(options.to_slot))
  end
  if options.to_limit then
    print("filling up to "..tostring(options.to_limit).." items per container")
  end
  if options.transfer_limit then
    print("transfering up to "..tostring(options.transfer_limit).." items per iteration")
  end

  local not_string = " "
  if options.negate then not_string = " not " end
  if #filters == 1 then
    print("only the items"..not_string.."matching the filter")
  elseif #filters > 1 then
    print("only the items"..not_string.."matching any of the "..tostring(#filters).." filters")
  end

  return true
end

-- if the computer has storage (aka. is a turtle)
-- we'd like to be able to transfer to it
local self = nil
local function determine_self()
  if not turtle then return end
  for _,dir in ipairs({"top","front","bottom","back"}) do
    local p = peripheral.wrap(dir)
    --print(p)
    if p and p.getNameLocal then
      self = p.getNameLocal()
      return
    end
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

local function chest_wrap(chest_name)
  local c = peripheral.wrap(chest_name)
  if not c then
    error("failed to wrap "..chest_name)
  end
  if c.getID then
    local success
    success, c = pcall(c.getInventory)
    if not success then
      return nil
    end
  end
  return c
end

local function transfer(from_slot,to_slot,count)
  if count <= 0 then
    return 0
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
    turtle.select(from_slot.slot_number)
    -- this bs doesn't return how many items were moved
    turtle.transferTo(to_slot.slot_number,count)
    -- so we'll just trust that the math we used to get `count` is correct
    return count
  end
  error("CANNOT DO TRANSFER BETWEEN "..from_slot.chest_name.." AND "..to_slot.chest_name)
end

local limits_cache = {}
local function chest_list(chest)
  local cannot_wrap = false
  local must_wrap = false
  if chest == "void" then
    local l = {}
    cannot_wrap = true
    must_wrap = true
    return l, cannot_wrap, must_wrap
  end
  if chest == "self" then
    cannot_wrap = true
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
    return l, cannot_wrap, must_wrap
  end
  local c = peripheral.wrap(chest)
  if not c then
    error("failed to wrap "..chest_name)
  end
  if c.getID then
    -- this is actually a bound introspection module?
    must_wrap = true
    local success
    success, c = pcall(c.getInventory)
    if not success then
      return {}, cannot_wrap, must_wrap
    end
  end
  local l = c.list()
  for i,item in pairs(l) do
    --print(i)
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
  return l, cannot_wrap, must_wrap
end

local function chest_size(chest)
  if chest == "void" then return 1 end
  if chest == "self" then return 16 end
  local c = peripheral.wrap(chest)
  if not c then
    error("failed to wrap "..chest_name)
  end
  if c.getID then
    local player_online = pcall(c.getID)
    if not player_online then 
      return 0
    else 
      return 36
    end
  end
  return c.size()
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
  if not options.count_all then
    if not matches_filters(filters,slot,options) then
      identifier = identifier.."x"
    end
  end

  return identifier
end

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
  local allowance = slot.count
  for _,limit in ipairs(options.limits) do
    if limit.type == "from" then
      local identifier = limit_slot_identifier(limit,slot)
      limit.items[identifier] = limit.items[identifier] or 0
      local amount_present = limit.items[identifier]
      allowance = math.min(allowance, amount_present - limit.limit)
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
      allowance = math.min(allowance, limit.limit - amount_present)
    elseif limit.type == "transfer" then
      local identifier = limit_slot_identifier(limit,slot,source_slot)
      limit.items[identifier] = limit.items[identifier] or 0
      local amount_transferred = limit.items[identifier]
      allowance = math.min(allowance, limit.limit - amount_transferred)
    end
  end
  return math.max(allowance,0)
end

local function hopper_step(from,to,peripherals,my_filters,my_options)
  filters = my_filters
  options = my_options
  local total_transferred = 0

  for _,limit in ipairs(options.limits) do
    limit.items = {}
  end
  local slots = {}
  for _,p in ipairs(peripherals) do
    local l, cannot_wrap, must_wrap = chest_list(p)
    for i=1,chest_size(p) do
      local slot = {}
      slot.chest_name = p
      slot.slot_number = i
      slot.is_source = false
      slot.is_dest = false
      slot.cannot_wrap = cannot_wrap
      slot.must_wrap = must_wrap
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
      table.insert(sources,s)
    elseif s.is_dest then
      table.insert(dests,s)
    end
  end
  table.sort(sources, function(left, right) 
    if left.count ~= right.count then
      return left.count < right.count
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
    if left.count ~= right.count then
      return left.count > right.count -- different here
    elseif left.chest_name ~= right.chest_name then
      return left.chest_name < right.chest_name
    elseif left.slot_number ~= right.slot_number then
      return left.slot_number < right.slot_number -- and here
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

  for si,s in pairs(sources) do
    if s.name ~= nil and matches_filters(filters,s,options) then
      for di,d in pairs(dests) do
        if d.name == nil or (s.name == d.name and s.nbt == d.nbt) then
          local sw = willing_to_give(s,options)
          if sw == 0 then
            break
          end
          local dw = willing_to_take(d,options,s)
          if dw > 0 then
            local to_transfer = math.min(sw,dw)
            local transferred = transfer(s,d,to_transfer)
            --print(s.chest_name..":"..s.slot_number.." --> "..d.chest_name..":"..d.slot_number)
            --print(si.."~>"..di)
            --print(to_transfer.."->"..transferred)
            if transferred ~= to_transfer then
              -- something went wrong, rescan and try again
              total_transferred = total_transferred + transferred
              return total_transferred + hopper_step(from,to,peripherals,my_filters,my_options)
            end
            s.count = s.count - transferred
            -- FIXME: void peripheral currently wrecks the
            -- chest data so it can't be cached
            if d.chest_name ~= "void" then
              d.count = d.count + transferred
              -- relevant if d was empty
              d.name = s.name
              d.nbt = s.nbt
              d.limit = s.limit
            end

            total_transferred = total_transferred + transferred
            for _,limit in ipairs(options.limits) do
              inform_limit_of_transfer(limit,s,d,transferred,options)
            end
          end
        end
      end
    end
  end

  return total_transferred
end

local function hopper_loop(from,to,filters,options)
  options = default_options(options)
  filters = default_filters(filters)

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

  -- TODO: check if sources or destinations is empty
  local valid = display_info(from,to,filters,options)
  if not valid then return end

  local start_time = os.epoch("utc")
  local total_transferred = 0
  while true do
    local transferred = hopper_step(from,to,peripherals,filters,options)
    local elapsed_time = os.epoch("utc")-start_time
    total_transferred = total_transferred + transferred
    line_to_start()
    term.write("transferred so far: "..total_transferred.." ("..(total_transferred*1000/elapsed_time).." i/s)")
    if options.once then
      break
    end
    sleep(options.sleep)
  end
  return total_transferred
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
      -- TODO: none of these options are global
      -- implement the `/` thing
      if args[i] == "-once" then
        options.once = true
      elseif args[i] == "-forever" then
        options.once = false
      elseif args[i] == "-quiet" then
        options.quiet = true
      elseif args[i] == "-verbose" then
        options.quiet = false
      elseif args[i] == "-negate" or args[i] == "-negated" then
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
      elseif args[i] == "-from_limit" then
        i = i+1
        table.insert(options.limits, { type="from", limit=tonumber(args[i]) } )
      elseif args[i] == "-to_limit" then
        i = i+1
        table.insert(options.limits, { type="to", limit=tonumber(args[i]) } )
      elseif args[i] == "-transfer_limit" then
        i = i+1
        table.insert(options.limits, { type="transfer", limit=tonumber(args[i]) } )
      elseif args[i] == "-per_slot" then
        options.limits[#options.limits].per_slot = true
        options.limits[#options.limits].per_chest = true
      elseif args[i] == "-per_chest" then
        options.limits[#options.limits].per_chest = true
      elseif args[i] == "-per_item" then
        options.limits[#options.limits].per_name = true
      elseif args[i] == "-per_nbt" then
        options.limits[#options.limits].per_name = true
        options.limits[#options.limits].per_nbt = true
      elseif args[i] == "-count_all" then
        options.count_all = true
      elseif args[i] == "-sleep" then
        i = i+1
        options.sleep = tonumber(args[i])
      else
        print("UNKNOWN ARGUMENT: "..args[i])
        return
      end
    else
      table.insert(filters, {name=args[i]})
    end

    i = i+1
  end

  return from,to,filters,options
end

local function hopper(args_string)
  local args = {}
  for arg in args_string:gmatch("%S+") do 
    table.insert(args, arg)
  end

  local from,to,filters,options = hopper_parser(args)
  if options.once == nil then
    options.once = true
  end
  if options.quiet == nil then
    options.quiet = true
  end
  return hopper_loop(from,to,filters,options)
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

  local amount = hopper_loop(hopper_parser(args))
  print("transferred amount: "..amount)
end

local args = {...}

return main(args)
