-- Copyright umnikos (Alex Stefanov) 2023
-- Licensed under MIT license
-- Version 1.2

-- TODO: take into account NBT data when stacking
-- TODO: parallelize inventory calls for super fast operations
-- TODO: use inventoryUpdate event instead of sleep()

-- TODO: figure out reasons why this isn't an accidental reimplementation of abstractInvLib.lua

local help_message = [[
hopper script v1.2, made by umnikos

usage: hopper {from} {to} [{item name}/{flag}]*
example: hopper *chest* *barrel* *:pink_wool

flags:
  -once : run the script only once instead of in a loop (undo with -forever)
  -quiet: print less things to the terminal (undo with -verbose)
  -from_slot [slot]: restrict pulling to a single slot
  -to_slot [slot]: restrict pushing to a single slot
  -from_limit [num]: keep at least this many matching items in every source chest
  -to_limit [num]: fill every destination chest with at most this many matching items
  -sleep [num]: set the delay in seconds between each iteration (default is 1)]]

-- further things of note:
-- - `self` is a valid peripheral name if you're running the script from a turtle connected to a wired modem
-- - you can import this file as a library with `require "hopper"`
-- - the script will prioritize taking from almost empty stacks and filling into almost full stacks

local function noop()
end

local print = print

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

local function is_empty(t)
  return next(t) == nil
end

-- FIXME: this does not escape pattern characters like `-`
local function glob(p, s)
  local p = "^"..string.gsub(p,"*",".*").."$"
  local res = string.find(s,p)
  return res ~= nil
end

local function default_options(options)
  if not options then
    options = {}
  end
  if options.quiet == nil then
    options.quiet = true
  end
  if options.once == nil then
    options.once = true
  end
  if options.sleep == nil then
    options.sleep = 1
  end
  --IDEA: to/from slot ranges instead of singular slots
  --if type(options.from_slot) == "number" then
  --  options.from_slot = {options.from_slot, options.from_slot}
  --end
  --if type(options.to_slot) == "number" then
  --  options.to_slot = {options.to_slot, options.to_slot}
  --end
  return options
end

local function default_filters(filters)
  if not filters then
    filters = {}
  end
  if type(filters) == "string" then
    filters = {filters}
  end
  return filters
end

local function display_info(from, to, sources, destinations, filters, options)
  if options.quiet then print = noop end

  print("hoppering from "..from)
  if options.from_slot then
    print("and only from slot "..tostring(options.from_slot))
  end
  if options.from_limit then
    print("keeping at least "..tostring(options.from_limit).." items in reserve per container")
  end
  if #sources == 0 then
    print("except there's nothing matching that description!")
    return false
  end
  print("to "..to)
  if #destinations == 0 then
    print("except there's nothing matching that description!")
    return false
  end
  if options.to_slot then
    print("and only to slot "..tostring(options.to_slot))
  end
  if options.to_limit then
    print("filling up to "..tostring(options.to_limit).." items per container")
  end

  if #filters == 1 and filters[1] ~= "*" then
    print("only the items matching the filter "..filters[1])
  elseif #filters > 1 then
    print("only the items matching any of the "..tostring(#filters).." filters")
  end

  return true
end

local function matches_filters(filters,s)
  if #filters == 0 then return true end
  for _,filter in pairs(filters) do
    --print(filter)
    if glob(filter,s) then
      return true
    end
  end
  return false
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
      --print("FOUND SELF")
      self = p.getNameLocal()
      return
    end
  end
end

local function transfer(from,to,from_slot,to_slot,count)
  if count <= 0 then
    --print("WARNING: transfering 0 or less items?!?")
    return 0
  end
  --print("TRANSFER! from "..from.." to "..to)
  if from ~= "self" then
    if to == "self" then to = self end
    return peripheral.call(from,"pushItems",to,from_slot,count,to_slot)
  else
    if to == "self" then
      turtle.select(from_slot)
      turtle.transferTo(to_slot,count)
    else
      return peripheral.call(to,"pullItems",self,from_slot,count,to_slot)
    end
  end
end

local limits_cache = {}
local function chest_list(chest)
  if chest ~= "self" then
    local c = peripheral.wrap(chest)
    local l = c.list()
    for i,item in pairs(l) do
      --print(i)
      if limits_cache[item.name] == nil then
        limits_cache[item.name] = c.getItemLimit(i)
      end
      l[i].limit = limits_cache[item.name]
    end
    return l
  else
    local l = {}
    for i=1,16 do
      l[i] = turtle.getItemDetail(i,true)
      if l[i] then
        --print(i)
        l[i].limit = l[i].maxCount
      end
    end
    return l
  end
end

local function chest_size(chest)
  if chest == "self" then return 16 end
  return peripheral.call(chest,"size")
end

local function hopper_step(from,to,sources,dests,filters,options)
  --print("hopper step")
  -- get all of the chests' contents
  -- which we will be updating internally
  -- in order to not have to list the chests
  -- over and over again
  local source_lists = {}
  local dest_lists = {}
  for _,source_name in ipairs(sources) do
    source_lists[source_name] = chest_list(source_name)
  end
  for _,dest_name in ipairs(dests) do
    dest_lists[dest_name] = chest_list(dest_name)
  end

  -- we will be iterating over item types to be moved
  -- as well as over source and destination chests
  -- in order to capitalize on knowing when the destinations are full
  -- and when the sources are empty
  -- so we can stop hoppering early
  local item_jobs = {}

  -- we will also prioritize filling items into slots
  -- that already have existing partial stacks of those items
  -- ideally there shouldn't be that many partial stacks
  -- so this won't be horribly slow
  local partial_source_slots = {}
  local partial_dest_slots = {}

  -- for to/from limits we'll also need to know
  -- how many items per chest we can move
  -- of every item type
  local chest_contains = {}

  for source_name,source_list in pairs(source_lists) do
    chest_contains[source_name] = chest_contains[source_name] or {}
    for i,item in pairs(source_list) do
      if not (options.from_slot and options.from_slot ~= i) then
        if matches_filters(filters,item.name) then
          if not item_jobs[item.name] then
            item_jobs[item.name] = 0
            partial_source_slots[item.name] = {}
            partial_dest_slots[item.name] = {}
          end

          item_jobs[item.name] = item_jobs[item.name] + item.count
          chest_contains[source_name][item.name] = (chest_contains[source_name][item.name] or 0) + item.count
          if item.count > 0 and item.count < item.limit then
            partial_source_slots[item.name] = partial_source_slots[item.name] or {}
            partial_source_slots[item.name][item.count] = partial_source_slots[item.name][item.count] or {}
            table.insert(partial_source_slots[item.name][item.count], {source_name,i})
          end
        end
      end
    end
  end

  for dest_name,dest_list in pairs(dest_lists) do
    chest_contains[dest_name] = chest_contains[dest_name] or {}
    for i,item in pairs(dest_list) do
      if not (options.to_slot and options.to_slot ~= i) then
        if (item_jobs[item.name] or 0) > 0 then -- item name matches filter if so
          chest_contains[dest_name][item.name] = (chest_contains[dest_name][item.name] or 0) + item.count
          if item.count > 0 and item.count < item.limit then
            partial_dest_slots[item.name] = partial_dest_slots[item.name] or {}
            partial_dest_slots[item.name][item.count] = partial_dest_slots[item.name][item.count] or {}
            table.insert(partial_dest_slots[item.name][item.count], {dest_name,i})
          end
        end
      end
    end
  end

  --print(dump(partial_source_slots))
  --print(dump(partial_dest_slots))

  -- and now for the actual hoppering
  for item_name,_ in pairs(item_jobs) do
    -- we first do it for the partially filled source slots only
    -- into partially filled destinations only
    local s = partial_source_slots[item_name]
    local source_counts = {}
    for c,_ in pairs(s) do table.insert(source_counts,c) end
    local d = partial_dest_slots[item_name]
    local dest_counts = {}
    for c,_ in pairs(d) do table.insert(dest_counts,c) end
    table.sort(source_counts)
    table.sort(dest_counts)
    local si = 1    -- container index
    local sii = nil -- slot index
    local ssi = nil -- whole container index
    local ssii = nil -- whole container slot
    local di = #dest_counts  -- container index
    local dii = nil          -- slot index
    local ddi = nil          -- whole container index

    if si > #source_counts then
      ssi = #sources
      ssii = chest_size(sources[ssi])
    end

    local source_name, source_i, source_amount
    local dest_name, dest_i, dest_amount
    local function get_source()
      if ssi == nil then
        if not sii then sii = #s[source_counts[si]] end
        local source_name, source_i = table.unpack(s[source_counts[si]][sii])
        local source_amount = source_lists[source_name][source_i].count
        return source_name, source_i, source_amount
      else
        while ssi > 0 do
          if options.from_slot then ssii = options.from_slot end
          local item_found = source_lists[sources[ssi]][ssii]
          -- TODO: replace ~= with comparison operators
          if item_found and item_found.count > 0 and item_found.name == item_name and chest_contains[sources[ssi]][item_name] ~= options.from_limit then
            return sources[ssi], ssii, item_found.count
          end
          ssii = ssii - 1
          if ssii <= 0 or (options.from_slot and ssii < options.from_slot) then
            ssi = ssi - 1
            if ssi <= 0 then
              break
            end
            ssii = chest_size(sources[ssi])
          end
        end
        return nil, nil, nil
      end
    end
    local function update_source(amount, transferred) -- planned vs actual transffered amount
      source_lists[source_name][source_i].count = source_lists[source_name][source_i].count - amount
      chest_contains[source_name][item_name] = (chest_contains[source_name][item_name] or 0) - amount
      if ssi == nil then
        if source_lists[source_name][source_i].count == 0 or chest_contains[source_name][item_name] == options.from_limit then
          sii = sii - 1
        end
        if sii <= 0 then
          si = si + 1
          sii = nil
          if si > #source_counts then
            ssi = #sources
            ssii = chest_size(sources[ssi])
          end
        end
      end
    end
    local function get_dest()
      if di and di < 1 then
        ddi = #dests
        di = nil
        dii = nil
      end
      if ddi == nil then
        if not dii then dii = #d[dest_counts[di]] end
        local dest_name, dest_i = table.unpack(d[dest_counts[di]][dii])
        local dest_amount = dest_lists[dest_name][dest_i].limit - dest_lists[dest_name][dest_i].count
        return dest_name, dest_i, dest_amount
      else
        if options.to_slot then
          -- find chest where slot is empty
          while true do
            if ddi < 1 then break end
            if (chest_contains[dests[ddi]][item_name] or 0) ~= (options.to_limit or math.huge) then
              if dest_lists[dests[ddi]][options.to_slot] == nil then break end
              if dest_lists[dests[ddi]][options.to_slot].count == 0 then break end
            end
            ddi = ddi - 1
          end
          return dests[ddi], options.to_slot, math.huge
        else
          -- just shove into the chest and move to the next one if 0 get moved
          return dests[ddi], nil, math.huge
        end
      end
    end
    local function update_dest(amount, transferred)
      chest_contains[dest_name][item_name] = (chest_contains[dest_name][item_name] or 0) + amount
      if ddi == nil then
        -- TODO: this needs to be a thing even if ddi is not nil, else the list becomes invalid and is not reusable
        dest_lists[dest_name][dest_i].count = dest_lists[dest_name][dest_i].count + amount
        if dest_lists[dest_name][dest_i].limit - dest_lists[dest_name][dest_i].count == 0 or chest_contains[dest_name][item_name] == options.to_limit then
          dii = dii - 1
        end
        if dii <= 0 then
          di = di - 1
          dii = nil
        end
      else
        --print(transferred == 0 and (chest_contains[source_name][item_name] or 0) ~= options.from_limit)
        if transferred == 0 and (chest_contains[source_name][item_name] or 0) ~= options.from_limit then
          ddi = ddi - 1
        end
        --print(ddi)
      end
    end

    while true do
      if item_jobs[item_name] <= 0 then break end
      source_name, source_i, source_amount = get_source()
      if source_name == nil then break end
      dest_name, dest_i, dest_amount = get_dest()
      if dest_name == nil then break end
      --print(dump(chest_contains))
      local amount = math.min(source_amount,
                              dest_amount,
                              (options.to_limit or math.huge) - (chest_contains[dest_name][item_name] or 0),
                              (chest_contains[source_name][item_name] or 0) - (options.from_limit or 0)
                             )
      local transferred = transfer(source_name,dest_name,source_i,dest_i,amount)

      update_source(amount, transferred)
      update_dest(amount, transferred)
    end

  end

end

local function hopper(from,to,filters,options)
  options = default_options(options)
  filters = default_filters(filters)

  determine_self()
  --print("SELF IS:")
  --print(self)

  local peripherals = peripheral.getNames()
  if self then
    table.insert(peripherals,"self")
  end

  local sources = {}
  local destinations = {}
  for i,per in ipairs(peripherals) do
    if glob(from,per) then
      -- prevent the source and the destination ever being the same
      -- (if a chest matches both, it's only a destination)
      if (not glob(to,per)) or (options.to_slot and options.from_slot and options.from_slot ~= options.to_slot) then
        sources[#sources+1] = per
      end
    end
    if glob(to,per) then
      destinations[#destinations+1] = per
    end
  end

  local valid = display_info(from,to,sources,destinations,filters,options)
  if not valid then return end

  while true do
    hopper_step(from,to,sources,destinations,filters,options)
    if options.once then
      break
    end
    sleep(options.sleep)
  end
end


local args = {...}

local function main()

  if args[1] == "hopper" then
    return hopper
  end

  if #args < 2 then
      print(help_message)
      return
  end
  local from = args[1]
  local to = args[2]
  local options = {}
  options.once = false
  options.quiet = false

  local filters = {}
  local i=3
  while i <= #args do
    if glob("-*",args[i]) then
      if args[i] == "-once" then
        --print("(only once!)")
        options.once = true
      elseif args[i] == "-forever" then
        options.once = false
      elseif args[i] == "-quiet" then
        options.quiet = true
      elseif args[i] == "-verbose" then
        options.quiet = false
      elseif args[i] == "-from_slot" then
        i = i+1
        options.from_slot = tonumber(args[i])
      elseif args[i] == "-to_slot" then
        i = i+1
        options.to_slot = tonumber(args[i])
      elseif args[i] == "-from_limit" then
        i = i+1
        options.from_limit = tonumber(args[i])
      elseif args[i] == "-to_limit" then
        i = i+1
        options.to_limit = tonumber(args[i])
      elseif args[i] == "-sleep" then
        i = i+1
        options.sleep = tonumber(args[i])
      else
        print("UNKNOWN ARGUMENT: "..args[i])
        return
      end
    else
      filters[#filters+1] = args[i]
    end

    i = i+1
  end

  hopper(from,to,filters,options)
end

return main()
