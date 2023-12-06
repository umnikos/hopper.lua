-- Copyright umnikos (Alex Stefanov) 2023
-- Licensed under MIT license
local version = "v1.3.1 ALPHA6"

local help_message = [[
hopper script ]]..version..[[, made by umnikos

example usage: 
  hopper *chest* *barrel* *:pink_wool -negate

for more info check out the repo:
  https://github.com/umnikos/hopper.lua]]

-- -from_limit_max - will not take from source if it has more than this many items
-- -to_limit_min - will not send to source if it has less than this many items
-- -refill - alias for -to_limit_min 1 -per_chest -per_item
-- fixed a hot reloading bug
-- improved info display
-- -per_slot_number - like -per_slot but doesn't imply -per_chest (all n-th slots in all chests share a count)


-- pro tip when brewing:
-- hopper *chest* *brewing* *potion* -to_slot_range 1 3 -to_limit 1 -per_chest
-- hopper *chest* *brewing* *potion* -to_slot_range 1 3 -refill -per_nbt





-- TODO: print actually useful info on the screen
--  - a dot for every hopper_step retry (and debug info if the dots get too numerous)
--  - the stage hopper_step is currently in (for performance profiling)
--  - number of sources and destinations
--  - transfer count for the last iteration (useful with void)

-- TODO: rice cooker functionality
-- TODO: krist wallet pseudoperipherals

-- TODO: parallelize inventory calls for super fast operations
-- TODO: `/` for multiple hopper operations with the same scan (conveniently also implementing prioritization)
-- TODO: caching for inventories only hopper.lua has access to
-- TODO: conditional transfer (based on whether the previous command succeeded?)
  -- items can block each other, thus you can make a transfer happen only if that slot is free by passing items through said slot
-- TODO: some way to treat chests as queues
-- TODO: multiple sources and destinations, with separate -to_slot and -from_slot flags

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
-- cannot_wrap: the chest this slot is in cannot be wrapped
-- must_wrap: the chest this slot is in must be wrapped
-- after_action: identifies that some special action must be done after transferring to this slot
-- voided: how many of the items are physically there but are pretending to be missing

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
    --error("failed to wrap "..chest_name)
    return nil
  end
  if c.getInventory then
    local success
    success, c = pcall(c.getInventory)
    if not success then
      return nil
    end
  end
  if c and c.list then
    return c
  end
  return nil
end

local function transfer(from_slot,to_slot,count)
  if count <= 0 then
    return 0
  end
  if from_slot.chest_name == nil or to_slot.chest_name == nil then
    print("FOUND NIL CHEST")
    print(dump(from_slot))
    print(dump(to_slot))
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
  local after_action = false
  if chest == "void" then
    local l = {}
    cannot_wrap = true
    must_wrap = true
    after_action = true
    return l, cannot_wrap, must_wrap, after_action
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
    return l, cannot_wrap, must_wrap, after_action
  end
  local c = peripheral.wrap(chest)
  if not c then
    --error("failed to wrap "..chest_name)
    l = {}
    return l, cannot_wrap, must_wrap, after_action
  end
  if c.ejectDisk then
    c.ejectDisk()
    cannot_wrap = true
    after_action = true
    l = {}
    return l, cannot_wrap, must_wrap, after_action
  end
  if c.getInventory then
    -- this is actually a bound introspection module
    must_wrap = true
    local success
    success, c = pcall(c.getInventory)
    if not success then
      return {}, cannot_wrap, must_wrap, after_action
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
  return l, cannot_wrap, must_wrap, after_action
end

local function chest_size(chest)
  if chest == "void" then return 1 end
  if chest == "self" then return 16 end
  local c = peripheral.wrap(chest)
  if not c then
    --error("failed to wrap "..chest_name)
    return 0
  end
  if c.ejectDisk then
    return 1
  end
  if c.getInventory then
    local player_online = pcall(c.getInventory)
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

local function hopper_step(from,to,peripherals,my_filters,my_options,retrying_from_failure)
  filters = my_filters
  options = my_options
  local total_transferred = 0

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
    for i=1,chest_size(p) do
      local slot = {}
      slot.chest_name = p
      slot.slot_number = i
      slot.is_source = false
      slot.is_dest = false
      slot.cannot_wrap = cannot_wrap
      slot.must_wrap = must_wrap
      slot.after_action = after_action
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
            local success,transferred = pcall(transfer,s,d,to_transfer)
            --print(s.chest_name..":"..s.slot_number.." --> "..d.chest_name..":"..d.slot_number)
            --print(si.."~>"..di)
            --print(to_transfer.."->"..transferred)
            if not success or transferred ~= to_transfer then
              -- something went wrong, rescan and try again
              if not success then
                transferred = 0
              end
              total_transferred = total_transferred + transferred
              return total_transferred + hopper_step(from,to,peripherals,my_filters,my_options,true)
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
          end
        end
      end
    end
  end

  options = nil
  filters = nil
  return total_transferred
end

local function hopper_loop(from,to,filters,options)
  options = default_options(options)
  filters = default_filters(filters)

  local start_time = os.epoch("utc")
  local total_transferred = 0
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

    local transferred = hopper_step(from,to,peripherals,filters,options)
    local elapsed_time = os.epoch("utc")-start_time
    total_transferred = total_transferred + transferred
    line_to_start()
    term.write("transferred so far: "..total_transferred.." ("..(total_transferred*1000/elapsed_time).." i/s)    ")
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
  -- TODO: parallel info screen goes here.
  -- TODO: replace all prints with errors and get rid of the overload
  display_info(from,to,filters,options)
  return hopper_loop(from,to,filters,options)
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

  local amount = hopper_main(args)
  print("transferred amount: "..amount)
end

local args = {...}

return main(args)
