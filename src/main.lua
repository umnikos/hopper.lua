sides = {"top", "front", "bottom", "back", "right", "left"}

-- rarely used since it's slow on big objects
local function deepcopy(o)
  if type(o) == "table" then
    local n = {}
    for k,v in pairs(o) do
      n[k] = deepcopy(v)
    end
    return n
  else
    return o
  end
end

local function exitOnTerminate(f)
  local status, err = pcall(f)
  if status then
    return
  end
  if err == "Terminated" then
    return err
  end
  return error(err, 0)
end

-- call f a few times until it returns non-nil
-- this is meant to be used with inventory operations
-- TODO: replace with a watchdog thread that monitors reconnect/disconnect events
local function stubbornly(f, ...)
  for i = 1,5 do
    local res = {f(...)}
    if res[1] ~= nil then
      return table.unpack(res)
    end
  end
end

-- list of chests to not rescan
dont_rescan_patterns = {}

local function should_rescan(chest)
  for _,p in ipairs(dont_rescan_patterns) do
    if glob(p, chest) then
      return false
    end
  end
  return true
end

-- slot data structure:
-- chest_name: name of container holding that slot
-- chest_size: size of the container. might be nil, and might be less than the total number of slots
-- slot_number: the index of that slot in the chest. defaults to 0
-- name: name of item held in slot, nil if empty
-- nbt: nbt hash of item, nil if none
-- count: how much is there of this item, 0 if none
-- type: whether it's an item or fluid. nil for item, "f" for fluid
-- limit: how many items the slot can store, if nil then 64
-- limit_is_constant: if true then the slot can take the same amount of items regardless of that item type's stack size
-- duplicate: on an empty slot means to make a copy of it after it gets filled up (aka. it represents many empty slots)
-- is_source: whether this slot matches source slot critera
-- is_dest: whether this slot matches dest slot criteria
-- cannot_wrap: the chest this slot is in cannot be wrapped
-- must_wrap: the chest this slot is in must be wrapped
-- dest_after_action: a function to call after the slot receives items
-- - accepts dest slot, source slot, amount transferred
-- voided: how many of the items are physically there but are pretending to be missing
-- from_priority/to_priority: how early in the pattern match the chest appeared, lower number means higher priority

local function hardcoded_limit_overrides(c)
  local ok, types = pcall(function() return {peripheral.getType(c)} end)
  if not ok then return nil end
  for _,t in ipairs(types) do
    if t == "spectrum:bottomless_bundle" then
      return 1/0
    end
    if t == "slate_works:storage_loci" then
      return 1/0
    end
    if t == "minecraft:chiseled_bookshelf" then
      return 1, true
    end
    if t == "powah:energizing_orb" then
      return 1, true
    end
  end
  return nil
end

local function isVanilla(c)
  local ok, types = pcall(function() return {peripheral.getType(c)} end)
  if not ok then return false end
  for _,t in ipairs(types) do
    if string.find(t, "minecraft:.*") then
      return true
    end
  end
  return false
end

local function isStorageDrawer(c)
  local ok, types = pcall(function() return {peripheral.getType(c)} end)
  if not ok then return false end
  for _,t in ipairs(types) do
    if string.find(t, "storagedrawers:.*") then
      return true
    end
  end
  return false
end

local function isCreateProcessor(c)
  local ok, types = pcall(function() return {peripheral.getType(c)} end)
  if not ok then return false end
  for _,t in ipairs(types) do
    if t == "create:crushing_wheel_controller"
    or t == "create:depot" then
      return 1
    end
    if t == "basin" then
      return 9
    end
  end
  return nil
end

local function isPowahOrb(c)
  local ok, types = pcall(function() return {peripheral.getType(c)} end)
  if not ok then return false end
  for _,t in ipairs(types) do
    if t == "powah:energizing_orb" then
      return true
    end
  end
  return false
end

local function isStorageController(c)
  local ok, types = pcall(function() return {peripheral.getType(c)} end)
  if not ok then return false end
  for _,t in ipairs(types) do
    if string.find(t, "functionalstorage:storage_controller") then
      return true
    end
  end
  return false
end

local function isApotheosisLibrary(c)
  local ok, types = pcall(function() return {peripheral.getType(c)} end)
  if not ok then return false end
  for _,t in ipairs(types) do
    if t == "apotheosis:library"
    or t == "apotheosis:ender_library" then
      return true
    end
  end
  return false
end

local upw_max_item_transfer = 128 -- default value, we dynamically discover the exact value later
local upw_max_fluid_transfer = 65500 -- defaults vary but 65500 seems to be the smallest
local upw_max_energy_transfer = 1 -- not even remotely true but the real limit varies per peripheral

-- returns if container is an UnlimitedPeripheralWorks container
local function isUPW(c)
  if type(c) == "string" then
    c = peripheral.wrap(c)
  end
  if not c then
    -- anything else not wrappable is also probably some exception
    return false
  end
  if c.isUPW or c.items then
    return true
  else
    return false
  end
end

local function isMEBridge(c)
  if type(c) == "string" then
    c = peripheral.wrap(c)
  end
  if not c then
    -- anything else not wrappable is also probably some exception
    return false
  end
  if c.isMEBridge or c.importFluidFromPeripheral then
    return true
  else
    return false
  end
end

local function isAE2(c)
  if type(c) == "string" then
    c = peripheral.wrap(c)
  end
  if not c then
    -- anything else not wrappable is also probably some exception
    return false
  end
  if c.isAE2 or c.getCraftingCPUs then
    return true
  else
    return false
  end
end

local function is_sided(chest)
  for _,dir in pairs(sides) do
    if chest == dir then
      return true
    end
  end
  return false
end

local is_inventory_cache = {}
-- if this return false it's definitely not an inventory
-- if this returns true it *might* be an inventory
local function is_inventory(chest, recursed)
  if not recursed then
    if is_inventory_cache[chest] == nil then
      is_inventory_cache[chest] = is_inventory(chest, true)
    end
    return is_inventory_cache[chest]
  end
  if is_sided(chest) then
    return true -- it might change later so we just have to assume it's an inventory
  end
  if chest == "void" then
    return true
  end
  if chest == "self" then
    return true
  end
  local types = {peripheral.getType(chest)}
  local is_turtle = false
  for _,type in pairs(types) do
    if type == "turtle" then
      is_turtle = true
    end
    if PROVISIONS.options.energy then
      if type == "energy_storage" then
        return true
      end
    else
      for _,valid_type in pairs({"inventory", "item_storage", "fluid_storage", "drive", "manipulator", "meBridge"}) do
        if type == valid_type then
          return true
        end
      end
    end
  end
  if is_turtle then
    -- trying to wrap a "turtle" without "inventory" is a common mistake
    -- hence the custom error message
    error("Without the UnlimitedPeripheralWorks mod, turtles can only be transferred to/from using `self`")
  end
  return false
end

-- item name -> maxCount
local stack_sizes_cache = {}
-- item name ; item nbt -> displayName
local display_name_cache = {}
-- item name -> tags
local tags_cache = {}
setmetatable(display_name_cache, {
  __index = function(t, k)
    if not PROVISIONS.logging.transferred then
      -- the transferred hook is the only place where we use display names
      -- so if it's not present just don't bother fetching them
      return "PLACEHOLDER"
    end
  end,
})

local no_c = {
  list = function() return {} end,
}

local function chest_wrap(chest, recursed)
  -- for every possible chest must return an object with .list
  -- as well as possibly custom transfer methods
  local meta = {
    cannot_wrap = false,
    must_wrap = false,
    chest_name = chest,
    slot_number = 0,
    transfer_strikes = 0,
  }
  meta.__index = meta

  if not is_inventory(chest) then
    return no_c
  end

  if not recursed then
    local chest_wrap_cache = PROVISIONS.chest_wrap_cache
    if not chest_wrap_cache[chest] then
      chest_wrap_cache[chest] = {chest_wrap(chest, true)}
    end
    return table.unpack(chest_wrap_cache[chest])
  end

  local options = PROVISIONS.options

  if chest == "void" then
    meta.dest_after_action = function(d, s, transferred)
      s.count = s.count+transferred
      s.voided = (s.voided or 0)+transferred
    end
    local c = {
      list = function()
        local l = {
          {count = 0, limit = 1/0, duplicate = true},
          {count = 0, limit = 1/0, duplicate = true, type = "f"},
          {count = 0, limit = 1/0, duplicate = true, type = "e"},
        }
        for _,s in ipairs(l) do
          setmetatable(s, meta)
        end
        return l
      end,
    }
    return c
  end
  if chest == "self" then
    meta.cannot_wrap = true
    local c = {}
    if options.energy then
      c.list = function()
        local fuel_level = turtle.getFuelLevel()
        local fuel_limit = turtle.getFuelLimit()
        local s = {name = "turtleFuel", count = fuel_level, limit = fuel_limit, type = "e"}
        setmetatable(s, meta)
        return {s}
      end
    else
      c.list = function()
        local l = {}
        for i = 1,16 do
          l[i] = turtle.getItemDetail(i, false)
          if l[i] then
            if stack_sizes_cache[l[i].name] == nil
            or display_name_cache[l[i].name..";"..(l[i].nbt or "")] == nil then
              local details = turtle.getItemDetail(i, true)
              l[i] = details
              if details ~= nil then
                stack_sizes_cache[details.name] = details.maxCount
                display_name_cache[details.name..";"..(details.nbt or "")] = details.displayName
              end
            end
          else
            l[i] = {count = 0} -- empty slot
          end
          l[i].slot_number = i
          setmetatable(l[i], meta)
        end
        return l
      end
    end
    return c
  end
  local c = peripheral.wrap(chest)
  if not c then
    -- error("failed to wrap "..chest_name)
    return no_c
  end
  if c.ejectDisk then
    -- this a disk drive
    if options.energy then return no_c end
    c.ejectDisk()
    meta.cannot_wrap = true
    meta.dest_after_action = function(d, s, transferred)
      c.ejectDisk()
      d.count = 0
      d.name = nil
      d.nbt = ""
    end
    c.list = function()
      local slot = {count = 0, slot_number = 1}
      setmetatable(slot, meta)
      local l = {slot}
      return l
    end
    return c
  end
  if c.getInventory and not c.list then
    -- this is a bound introspection module
    meta.must_wrap = true
    if options.energy then return no_c end
    local success
    if options.ender then
      success, c = pcall(c.getEnder)
    else
      success, c = pcall(c.getInventory)
    end
    if not success then
      return no_c
    end
  end
  if c.getPatternsFor and not c.items then
    -- incorrectly wrapped AE2 system, UPW bug (computer needs to be placed last)
    error("Cannot wrap AE2 system correctly! Break and place this computer and try again.")
  end
  if isMEBridge(c) then
    -- ME bridge from Advanced Peripherals
    c.isMEBridge = true
    c.isAE2 = true
    if options.denySlotless then
      error("cannot use "..options.denySlotless.." when transferring to/from ME bridge")
    end

    meta.must_wrap = true -- special methods must be used
    c.list = function()
      local res = {}
      res = c.listItems()
      for _,i in pairs(res) do
        i.nbt = nil -- FIXME: figure out how to hash the nbt
        i.count = i.count or i.amount
        i.limit = 1/0
      end
      table.insert(res, {count = 0, duplicate = true})
      table.insert(res, {type = "f", limit = 1/0, count = 0, duplicate = true})
      return res
    end
    c.tanks = function()
      local res = {}
      for _,tank in ipairs(c.listFluid()) do
        table.insert(res, {
          name = tank.name,
          amount = tank.amount,
        })
      end
      return res
    end
    c.size = nil
    c.pushItems = function(other_peripheral, from_slot_identifier, count, to_slot_number, additional_info)
      local item_name = string.match(from_slot_identifier, "[^;]*")
      return c.exportItemToPeripheral({name = item_name, count = count}, other_peripheral)
    end
    c.pullItems = function(other_peripheral, from_slot_number, count, to_slot_number, additional_info)
      local item_name = nil
      for _,s in pairs(additional_info) do
        item_name = s.name
        break
      end
      return c.importItemFromPeripheral({name = item_name, count = count}, other_peripheral)
    end
    c.pushFluid = function(to, limit, itemname)
      return c.exportFluidToPeripheral({name = itemname, count = limit}, to)
    end
    c.pullFluid = function(from, limit, itemname)
      return c.importFluidFromPeripheral({name = itemname, count = limit}, from)
    end
  end
  if isUPW(c) then
    -- this is an UnlimitedPeripheralWorks inventory
    c.isUPW = true
    if isAE2(c) then
      c.isAE2 = true
    end
    if options.denySlotless then
      error("cannot use "..options.denySlotless.." when transferring to/from UPW peripheral")
    end

    meta.must_wrap = true -- UPW forces us to use its own functions when interacting with a regular inventory
    c.list = function()
      local amounts = {}
      for _,i in ipairs(c.items()) do
        local id = i.name..";"..(i.nbt or "")
        if not amounts[id] then
          amounts[id] = {name = i.name, nbt = i.nbt, maxCount = i.maxCount, displayName = i.displayName, tags = i.tags, count = 0, limit = 1/0}
        end
        amounts[id].count = amounts[id].count+i.count
      end
      local res = {}
      for _,a in pairs(amounts) do
        local slot = a
        table.insert(res, slot)
      end
      table.insert(res, {count = 0, limit = 1/0, duplicate = true})
      return res
    end
    c.size = nil
    c.pushItemRaw = c.pushItem
    c.pullItemRaw = c.pullItem
    c.pushItem = function(to, query, limit)
      -- pushItem and pullItem are rate limited
      -- so we have to keep calling it over and over
      local total = 0
      while true do
        local amount = c.pushItemRaw(to, query, limit-total)
        total = total+amount
        if amount < upw_max_item_transfer or total == limit then
          return total
        end
      end
    end
    c.pullItem = function(from, query, limit)
      -- pushItem and pullItem are rate limited
      -- so we have to keep calling it over and over
      local total = 0
      while true do
        local amount = c.pullItemRaw(from, query, limit-total)
        total = total+amount
        if amount < upw_max_item_transfer or total == limit then
          return total
        end
      end
    end
    c.pushItems = function(other_peripheral, from_slot_identifier, count, to_slot_number, additional_info)
      local item_name = string.match(from_slot_identifier, "[^;]*")
      return c.pushItem(other_peripheral, item_name, count)
    end
    c.pullItems = function(other_peripheral, from_slot_number, count, to_slot_number, additional_info)
      local item_name = nil
      for _,s in pairs(additional_info) do
        item_name = s.name
        break
      end
      return c.pullItem(other_peripheral, item_name, count)
    end
  end
  if not (c.list or c.tanks or c.pushEnergy) then
    -- failed to wrap it for some reason
    return no_c
  end
  local cc = {}
  cc.list = function()
    local l = {}
    local s
    local tanks
    local early_return
    PROVISIONS.scan_task_manager:await({
      function()
        if c.list then
          l = stubbornly(c.list, true)
          if not l then
            early_return = true
          end
        end
      end,
      function()
        if c.tanks then
          tanks = stubbornly(c.tanks)
          if not tanks then
            early_return = true
          end
        end
      end,
      function()
        if c.size then
          s = stubbornly(c.size)
          if not s then
            early_return = true
          end
        end
      end,
    })
    if early_return then
      return {}
    end

    for i,item in pairs(l) do
      if item.name then
        if stack_sizes_cache[item.name] == nil
        or display_name_cache[item.name..";"..(item.nbt or "")] == nil then
          -- 1.12 cc + plethora calls getItemDetail "getItemMeta"
          -- I am no longer sure where exactly getItemDetailForge is found but it doesn't hurt to check for it
          c.getItemDetail = c.getItemDetail or c.getItemMeta or c.getItemDetailForge

          if not l[i].maxCount and c.getItemDetail then
            local details = stubbornly(c.getItemDetail, i)
            if not details then return {} end
            l[i] = details
          end

          if l[i].maxCount then
            stack_sizes_cache[l[i].name] = l[i].maxCount
          end
          if l[i].displayName then
            display_name_cache[l[i].name..";"..(l[i].nbt or "")] = l[i].displayName
          end
          if l[i].tags then
            tags_cache[l[i].name] = l[i].tags
          end
        end
      end
    end
    if s then
      meta.chest_size = s
      for i = 1,s do
        if l[i] == nil then
          l[i] = {count = 0} -- fill out empty slots
        end
        l[i].slot_number = i
      end
    end

    if s and s > 1 then
      -- create processing blocks have multiple slots on forge but insertion is only possible on the first slot
      local create_processor_slots = isCreateProcessor(c)
      if create_processor_slots then
        meta.never_dest = true
        for i = 1,create_processor_slots do
          l[i].never_dest = false
        end
      elseif isPowahOrb(c) then
        l[1].never_dest = true
        for i = 2,s do
          l[i].never_source = true
        end
      end
    end

    local upw_configuration = {}
    if c.getConfiguration then
      upw_configuration = c.getConfiguration()
      upw_max_item_transfer = upw_configuration.itemStorageTransferLimit or upw_max_item_transfer
      upw_max_item_transfer = upw_configuration.fluidStorageTransferLimit or upw_max_item_transfer
    end

    local limit_override, limit_is_constant = hardcoded_limit_overrides(c)
    if (not limit_override) and c.getItemLimit then
      -- takes result of getItemLimit and the item name and returns adjusted limit
      local function limit_calculation(lim, name)
        if not name then return lim end
        return lim*64/stack_sizes_cache[name]
      end

      if     (c.getConfiguration and not upw_configuration.implementationProvider) -- old UPW fucks up getItemLimit
      or     isVanilla(c) -- getItemLimit is broken for vanilla chests on forge. it works on fabric but there's no way to know if we're on forge so all vanilla limits are hardcoded instead
      then
        -- do nothing
      elseif isStorageDrawer(c) then -- the drawers from the storage drawers mod have a very messed up api that needs a ton of special casing
        for i,item in pairs(l) do
          local lim = stubbornly(c.getItemLimit, i)
          if not lim then return {} end
          if i == 1 and lim == 2^31-1 then
            -- weird first slot that we just ignore
            l[1] = nil
          else
            limit_override = limit_calculation(lim, item.name)
            if limit_override == 64 then limit_override = nil end
            break
          end
        end
      elseif isStorageController(c) then -- storage controllers have different limits for each slot so we need to set all of them individually
        local tasks = {}
        for i,item in pairs(l) do
          table.insert(tasks, function()
            local lim = stubbornly(c.getItemLimit, i)
            if not lim then return {} end
            local limit = limit_calculation(lim, item.name)
            if limit == 64 then limit = nil end
            l[i].limit = limit
          end)
        end
        PROVISIONS.scan_task_manager:await(tasks)
      else
        for i,item in pairs(l) do
          local lim = stubbornly(c.getItemLimit, i)
          if not lim then return {} end
          limit_override = limit_calculation(lim, item.name)
          if limit_override == 64 then limit_override = nil end
          break
        end
      end
    end
    if limit_override == 1 then
      -- otherwise it makes no sense
      limit_is_constant = true

      if isApotheosisLibrary(c) then
        -- apotheosis library swallows books instantly
        -- it has a slot limit of 1 so we only need to check here
        meta.dest_after_action = function(d, s, transferred)
          d.count = 0
          d.name = nil
          d.nbt = ""
        end
      end
    end
    if limit_override then
      for _,item in pairs(l) do
        item.limit = limit_override
        item.limit_is_constant = limit_is_constant
      end
    end
    local fluid_start = 100000 -- TODO: change this to omega
    if tanks then
      -- FIXME: how do i fetch displayname of fluids????
      for fi,fluid in pairs(tanks) do
        if fluid.name ~= "minecraft:empty" then
          table.insert(l, fluid_start+fi, {
            name = fluid.name,
            count = math.max(fluid.amount, 1), -- api rounds all amounts down, so amounts <1mB appear as 0, yet take up space
            limit = 1/0, -- not really, but there's no way to know the real limit
            type = "f",
          })
        else
          table.insert(l, fluid_start+fi, {type = "f", limit = 1/0, count = 0})
        end
      end
      if c.isAE2 or c.getInfo then
        table.insert(l, fluid_start, {type = "f", limit = 1/0, count = 0, duplicate = true})
      end
    end

    for _,s in pairs(l) do
      setmetatable(s, meta)
    end

    return l
  end
  if options.energy then
    cc.list = function()
      if not c.pushEnergy then return {} end
      local energy_amount
      local energy_unit
      local energy_limit
      PROVISIONS.scan_task_manager:await({
        function()
          energy_amount = stubbornly(c.getEnergy)%(1/0)
        end,
        function()
          energy_unit = stubbornly(c.getEnergyUnit)
        end,
        function()
          energy_limit = (stubbornly(c.getEnergyCapacity)-1)%(1/0)+1
        end,
      })
      if not (energy_amount and energy_unit and energy_limit) then
        return {}
      end
      local s = {name = energy_unit, count = energy_amount, limit = energy_limit, type = "e"}
      setmetatable(s, meta)
      return {s}
    end
  end
  cc.pushEnergy = function(to, limit, query)
    -- pushEnergy and pullEnergy are rate limited
    -- so we have to keep calling it over and over
    local total = 0
    while true do
      local amount = c.pushEnergy(to, limit-total, query)
      total = total+amount
      if amount < upw_max_energy_transfer or total == limit then
        return total
      end
    end
  end
  cc.pullEnergy = function(from, limit, query)
    -- pushEnergy and pullEnergy are rate limited
    -- so we have to keep calling it over and over
    local total = 0
    while true do
      local amount = c.pullEnergy(from, limit-total, query)
      total = total+amount
      if amount < upw_max_energy_transfer or total == limit then
        return total
      end
    end
  end
  cc.pushFluid = function(to, limit, query)
    -- pushFluid and pullFluid are rate limited
    -- so we have to keep calling it over and over
    local total = 0
    while true do
      local amount = c.pushFluid(to, limit-total, query)
      total = total+amount
      if amount < upw_max_fluid_transfer or total == limit then
        return total
      end
    end
  end
  cc.pullFluid = function(from, limit, query)
    -- pushFluid and pullFluid are rate limited
    -- so we have to keep calling it over and over
    local total = 0
    while true do
      local amount = c.pullFluid(from, limit-total, query)
      total = total+amount
      if amount < upw_max_fluid_transfer or total == limit then
        return total
      end
    end
  end
  cc.pullItems = c.pullItems
  cc.pushItems = c.pushItems
  cc.isAE2 = c.isAE2
  cc.isMEBridge = c.isMEBridge
  cc.isUPW = c.isUPW
  cc.pullItem = c.pullItem
  cc.pushItem = c.pushItem
  return cc
end

local function transfer(from_slot, to_slot, count)
  local myself = PROVISIONS.myself
  if count <= 0 then
    return 0
  end
  if from_slot.chest_name == nil then
    error("BUG DETECTED: nil source chest?")
  end
  if to_slot.chest_name == nil then
    error("BUG DETECTED: nil dest chest?")
  end
  if from_slot.type ~= to_slot.type then
    error("item type mismatch: "..(from_slot.type or "nil").." -> "..(to_slot.type or "nil"))
  end
  if to_slot.chest_name == "void" then
    -- the void consumes all that you give it
    return count
  end
  if from_slot.type == "e" then
    -- energy are to be dealt with here, separately.
    if (not from_slot.cannot_wrap) and (not to_slot.must_wrap) then
      local other_peripheral = to_slot.chest_name
      if other_peripheral == "self" then other_peripheral = myself:local_name(from_slot.chest_name) end
      return chest_wrap(from_slot.chest_name).pushEnergy(other_peripheral, count, from_slot.name)
    end
    if (not from_slot.must_wrap) and (not to_slot.cannot_wrap) then
      local other_peripheral = from_slot.chest_name
      if other_peripheral == "self" then other_peripheral = myself:local_name(to_slot.chest_name) end
      return chest_wrap(to_slot.chest_name).pullEnergy(other_peripheral, count, from_slot.name)
    end
    error("cannot do energy transfer between "..from_slot.chest_name.." and "..to_slot.chest_name)
  end
  if from_slot.type == "f" then
    -- fluids are to be dealt with here, separately.
    if from_slot.count == count then
      count = count+1 -- handle stray millibuckets that weren't shown
    end
    if (not from_slot.cannot_wrap) and (not to_slot.must_wrap) then
      return chest_wrap(from_slot.chest_name).pushFluid(to_slot.chest_name, count, from_slot.name)
    end
    if (not from_slot.must_wrap) and (not to_slot.cannot_wrap) then
      return chest_wrap(to_slot.chest_name).pullFluid(from_slot.chest_name, count, from_slot.name)
    end
    if isUPW(chest_wrap(from_slot.chest_name)) and isUPW(chest_wrap(to_slot.chest_name)) then
      return chest_wrap(from_slot.chest_name).pushFluid(to_slot.chest_name, count, from_slot.name)
    end
    error("cannot do fluid transfer between "..from_slot.chest_name.." and "..to_slot.chest_name)
  end
  if (not from_slot.cannot_wrap) and (not to_slot.must_wrap) then
    local other_peripheral = to_slot.chest_name
    if other_peripheral == "self" then other_peripheral = myself:local_name(from_slot.chest_name) end
    local c = chest_wrap(from_slot.chest_name)
    if not c then
      return 0
    end
    local from_slot_number = from_slot.slot_number
    local additional_info = nil
    if isUPW(c) or isMEBridge(c) then
      from_slot_number = from_slot.name..";"..(from_slot.nbt or "")
      additional_info = {[to_slot.slot_number] = {name = to_slot.name, nbt = to_slot.nbt, count = to_slot.count}}
    end
    return c.pushItems(other_peripheral, from_slot_number, count, to_slot.slot_number, additional_info)
  end
  if (not to_slot.cannot_wrap) and (not from_slot.must_wrap) then
    local other_peripheral = from_slot.chest_name
    if other_peripheral == "self" then other_peripheral = myself:local_name(to_slot.chest_name) end
    local c = chest_wrap(to_slot.chest_name)
    if not c then
      return 0
    end
    local additional_info = nil
    if isUPW(c) or isMEBridge(c) then
      additional_info = {[from_slot.slot_number] = {name = from_slot.name, nbt = from_slot.nbt, count = from_slot.count}}
    end
    return c.pullItems(other_peripheral, from_slot.slot_number, count, to_slot.slot_number, additional_info)
  end
  if from_slot.chest_name == "self" and to_slot.chest_name == "self" then
    return myself:transfer(from_slot.slot_number, to_slot.slot_number, count)
  end
  local cf = chest_wrap(from_slot.chest_name)
  local ct = chest_wrap(to_slot.chest_name)
  if isUPW(cf) and isUPW(ct) then
    local c = cf
    return c.pushItem(to_slot.chest_name, from_slot.name, count)
  end
  error("cannot do transfer between "..from_slot.chest_name.." and "..to_slot.chest_name)
end

local function num_in_ranges(num, ranges, size)
  size = size or 1/0
  for _,range in ipairs(ranges) do
    if type(range) == "number" then
      local target = range
      if target < 0 then
        target = size+1+target
      end
      if num == target then
        return true
      end
    elseif type(range) == "table" then
      local min = range[1]
      local max = range[2]
      if min < 0 then
        min = size+1+min
      end
      if max < 0 then
        max = size+1+max
      end
      if min <= num and num <= max then
        return true
      end
    end
  end
  return false
end

local function has_tag(tag, name)
  return tags_cache[name][tag]
end

-- check if slot matches a specific filter
local function filter_matches(slot, filter)
  if type(filter) == "function" then
    -- passable through the table api
    return filter({
      chest_name = slot.chest_name,
      chest_size = slot.chest_size,
      slot_number = slot.slot_number,
      name = slot.name,
      nbt = slot.nbt,
      count = slot.count-(slot.voided or 0),
      type = slot.type or "i",
      tags = deepcopy(tags_cache[slot.name]),
    })
  else
    local filter_is_empty = true
    if filter.none then
      filter_is_empty = false
      local filter_list = filter.none
      if filter_list[1] == nil then
        filter_list = {filter_list}
      end
      for _,f in ipairs(filter_list) do
        if filter_matches(slot, f) then
          return false
        end
      end
    end
    if filter.all then
      filter_is_empty = false
      for _,f in ipairs(filter.all) do
        if not filter_matches(slot, f) then
          return false
        end
      end
    end
    if filter.any then
      filter_is_empty = false
      local matches_any = false
      for _,f in ipairs(filter.any) do
        if filter_matches(slot, f) then
          matches_any = true
          break
        end
      end
      if not matches_any then
        return false
      end
    end
    if filter.name then
      filter_is_empty = false
      if not glob(filter.name, slot.name) then
        return false
      end
    end
    if filter.tag then
      filter_is_empty = false
      if not has_tag(filter.tag, slot.name) then
        return false
      end
    end
    -- TODO: add a way to specify matching only items without nbt data in string api
    if filter.nbt then
      filter_is_empty = false
      if not (slot.nbt and glob(filter.nbt, slot.nbt)) then
        return false
      end
    end
    if filter_is_empty then
      error("ERROR: Empty filter struct has been passed in!")
    end
    return true
  end
end

-- check if slot matches the current command's filters (respecting -negate)
local function matches_filters(slot)
  local filters = PROVISIONS.filters
  local options = PROVISIONS.options
  if slot.name == nil then
    error("SLOT NAME IS NIL")
  end

  local res = nil
  if #filters == 0 then
    res = true
  else
    res = false
    for _,filter in pairs(filters) do
      if filter_matches(slot, filter) then
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

local function mark_sources(slots, from)
  local filters = PROVISIONS.filters
  local options = PROVISIONS.options
  for _,s in ipairs(slots) do
    if s.from_priority then
      s.is_source = true
      if s.never_source then
        s.is_source = false
      end
      if options.from_slot then
        s.is_source = num_in_ranges(s.slot_number, options.from_slot, s.chest_size)
      end
    end
  end
end

local function mark_dests(slots, to)
  local filters = PROVISIONS.filters
  local options = PROVISIONS.options
  for _,s in ipairs(slots) do
    if s.to_priority then
      s.is_dest = true
      if s.never_dest then
        s.is_dest = false
      end
      if s.is_dest and options.to_slot then
        s.is_dest = num_in_ranges(s.slot_number, options.to_slot, s.chest_size)
      end
    end
  end
end

local function unmark_overlap_slots(slots)
  local options = PROVISIONS.options
  for _,s in ipairs(slots) do
    if s.is_source and s.is_dest then
      -- TODO: option to choose how this gets resolved
      -- currently defaults to being dest
      s.is_source = false
    end
  end
end

local function limit_slot_identifier(limit, primary_slot, other_slot)
  local options = PROVISIONS.options
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
    error("limit_slot_identifier was given two empty slots", 2)
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
    identifier = identifier..(slot.type or "")
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

local function inform_limit_of_slot(limit, slot)
  local options = PROVISIONS.options
  if slot.name == nil then return end
  if limit.type == "transfer" then return end
  if limit.type == "from" and (not slot.is_source) then return end
  if limit.type == "to" and (not slot.is_dest) then return end
  -- from and to limits follow
  local identifier = limit_slot_identifier(limit, slot)
  limit.items[identifier] = (limit.items[identifier] or 0)+slot.count
end

local function inform_limit_of_transfer(limit, from, to, amount)
  local options = PROVISIONS.options
  local from_identifier = limit_slot_identifier(limit, from, to)
  local to_identifier = limit_slot_identifier(limit, to, from)
  if limit.items[from_identifier] == nil then
    limit.items[from_identifier] = 0
  end
  if limit.items[to_identifier] == nil then
    limit.items[to_identifier] = 0
  end
  if limit.type == "transfer" then
    limit.items[from_identifier] = limit.items[from_identifier]+amount
    if from_identifier ~= to_identifier then
      if to.chest_name ~= "void" then
        limit.items[to_identifier] = limit.items[to_identifier]+amount
      end
    end
  elseif limit.type == "from" then
    limit.items[from_identifier] = limit.items[from_identifier]-amount
  elseif limit.type == "to" then
    limit.items[to_identifier] = limit.items[to_identifier]+amount
  else
    error("UNKNOWN LIMIT TYPE "..limit.type)
  end
end

local function willing_to_give(slot)
  local options = PROVISIONS.options
  if not slot.is_source then
    return 0
  end
  if slot.name == nil then
    return 0
  end
  local allowance = slot.count-(slot.voided or 0)
  for _,limit in ipairs(options.limits) do
    if limit.type == "from" then
      local identifier = limit_slot_identifier(limit, slot)
      limit.items[identifier] = limit.items[identifier] or 0
      local amount_present = limit.items[identifier]
      if limit.dir == "min" then
        allowance = math.min(allowance, amount_present-limit.limit)
      else
        if amount_present > limit.limit then
          allowance = 0
        end
      end
    elseif limit.type == "transfer" then
      local identifier = limit_slot_identifier(limit, slot)
      limit.items[identifier] = limit.items[identifier] or 0
      local amount_transferred = limit.items[identifier]
      allowance = math.min(allowance, limit.limit-amount_transferred)
    end
  end
  return math.max(allowance, 0)
end

local function willing_to_take(slot, source_slot)
  local options = PROVISIONS.options
  if not slot.is_dest then
    return 0
  end
  local allowance
  local max_capacity = 1/0
  if slot.limit_is_constant then
    max_capacity = (slot.limit or 64)
  elseif (slot.limit or 64) < 2^25 then -- FIXME: get rid of this magic constant
    local stack_size = stack_sizes_cache[source_slot.name]

    if stack_size then
      max_capacity = (slot.limit or 64)*stack_size/64
    end
  end
  allowance = max_capacity-slot.count
  for _,limit in ipairs(options.limits) do
    if limit.type == "to" then
      local identifier = limit_slot_identifier(limit, slot, source_slot)
      limit.items[identifier] = limit.items[identifier] or 0
      local amount_present = limit.items[identifier]
      if limit.dir == "max" then
        allowance = math.min(allowance, limit.limit-amount_present)
      else
        if amount_present < limit.limit then
          allowance = 0
        end
      end
    elseif limit.type == "transfer" then
      local identifier = limit_slot_identifier(limit, slot, source_slot)
      limit.items[identifier] = limit.items[identifier] or 0
      local amount_transferred = limit.items[identifier]
      allowance = math.min(allowance, limit.limit-amount_transferred)
    end
  end
  return math.max(allowance, 0)
end

local function sort_sources(sources)
  table.sort(sources, function(left, right)
    if left.from_priority ~= right.from_priority then
      return left.from_priority < right.from_priority
    elseif left.count-(left.voided or 0) ~= right.count-(right.voided or 0) then
      return left.count-(left.voided or 0) < right.count-(right.voided or 0)
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
    local left_space = (left.limit or stack_sizes_cache[left.name] or 64)-left.count
    local right_space = (right.limit or stack_sizes_cache[right.name] or 64)-right.count
    if left.to_priority ~= right.to_priority then
      return left.to_priority < right.to_priority
    elseif left_space ~= right_space then
      return left_space < right_space
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

local function slot_identifier(slot, include_slot_number)
  local ident = (slot.type or "")..";"..(slot.name or "")..";"..(slot.nbt or "")
  if include_slot_number then
    ident = ident..";"..slot.slot_number
  end
  return ident
end

local function empty_slot_identifier(slot, include_slot_number)
  local ident = (slot.type or "")..";;"
  if include_slot_number then
    ident = ident..";"..slot.slot_number
  end
  return ident
end

-- sorts destination slots into item types
-- returns a "name;nbt" -> [index] lookup table
-- which can be used to iterate through slots containing a particular item type
local function generate_dests_lookup(dests)
  local options = PROVISIONS.options
  local dests_lookup = {}
  for i,d in ipairs(dests) do -- since we do this right after sorting the resulting lookup table will also be sorted
    local ident = slot_identifier(d, options.preserve_slots)
    if not dests_lookup[ident] then
      dests_lookup[ident] = {slots = {}, s = 1, e = 0} -- s is first non-nil index, end is last non-nil index. if e<s then it's empty
    end
    dests_lookup[ident].e = dests_lookup[ident].e+1
    dests_lookup[ident].slots[dests_lookup[ident].e] = i
  end
  return dests_lookup
end

-- returns a mapping from peripheral name to modem name
-- this is used both as a replacement to peripheral.getNames
-- and to confirm transfers are happening between inventories on the same network
local function get_names_remote()
  local res = {}
  for _,side in ipairs(sides) do
    local m = peripheral.wrap(side)
    if m and m.getNamesRemote then
      for _,name in ipairs(m.getNamesRemote()) do
        res[name] = side
      end
    end
  end
  for _,side in ipairs(sides) do
    res[side] = "local" -- it might not exist but that doesn't matter
  end
  return res
end

local function get_all_peripheral_names(remote_names, from, to)
  local peripherals = {}
  table.insert(peripherals, "void")
  if turtle then
    table.insert(peripherals, "self")
  end
  for p,_ in pairs(remote_names) do
    table.insert(peripherals, p)
  end

  return peripherals
end

local function reset_limits()
  for _,limit in ipairs(PROVISIONS.options.limits) do
    if retrying_from_failure and limit.type == "transfer" then
      -- don't reset it
    else
      limit.items = {}
    end
  end
end

local function compute_priorities(chests, pattern)
  local priorities = {}
  for _,c in ipairs(chests) do
    priorities[c] = glob(pattern, c)
  end

  -- network groups through UPW
  local network_manager = peripheral.find("network_manager")
  if network_manager then
    for _,group in ipairs(stubbornly(network_manager.getGroups)) do
      local group_priority = glob(pattern, "group:"..group)
      if group_priority then
        local group_members = {stubbornly(network_manager.get, group)}
        for _,group_member in ipairs(group_members) do
          priorities[group_member] = math.min(priorities[group_member] or group_priority, group_priority)
        end
      end
    end
  end

  return priorities
end

-- chest_name -> list of slots
local scan_cache = {}

local function get_chest_contents(peripherals, from, to)
  local slots = {}
  local job_queue = {}

  local from_priorities = compute_priorities(peripherals, from)
  local to_priorities = compute_priorities(peripherals, to)

  for _,p in pairs(peripherals) do
    table.insert(job_queue, function()
      local from_priority = from_priorities[p]
      local to_priority = to_priorities[p]
      if not from_priority and not to_priority then
        -- ignore non-matching inv
      else
        local l = scan_cache[p]
        if l ~= nil then
          -- TODO: make an option to disable this
          for _,s in ipairs(l) do
            s.voided = 0
            s.transfer_strikes = nil
          end
        else
          l = chest_wrap(p).list()
          if not should_rescan(p) then
            scan_cache[p] = l
          end
        end
        if l ~= nil then
          for i,s in pairs(l) do
            s.is_source = false
            s.is_dest = false
            s.from_priority = from_priority
            s.to_priority = to_priority
            if s.name == nil then
              s.nbt = nil
              s.count = 0
            end
            table.insert(slots, s)
          end
        end
      end
    end)
  end
  PROVISIONS.scan_task_manager:await(job_queue)

  return slots
end

-- returns a new empty slot based on s the passed-in slot
-- this function also updates the scan cache
local function duplicate_slot(d)
  local newd = deepcopy(d)
  setmetatable(newd, getmetatable(d))
  newd.name = nil
  newd.nbt = nil
  newd.count = 0
  newd.slot_number = nil
  if scan_cache[newd.chest_name] then
    table.insert(scan_cache[newd.chest_name], newd)
  end
  return newd
end

local latest_warning = nil -- used to update latest_error if another error doesn't show up
-- TODO: get rid of warning and error globals!!!!

-- how many transfer strikes until the slot is kicked out
local transfer_strike_out = 3

local function hopper_step(from, to)
  latest_warning = nil

  PROVISIONS.hoppering_stage = "look"
  local remote_names = get_names_remote()
  local peripherals = get_all_peripheral_names(remote_names, from, to)

  PROVISIONS.hoppering_stage = "reset_limits"
  reset_limits()

  PROVISIONS.hoppering_stage = "scan"
  local slots = get_chest_contents(peripherals, from, to)

  PROVISIONS.hoppering_stage = "mark"
  mark_sources(slots, from)
  mark_dests(slots, to)
  unmark_overlap_slots(slots)
  for _,slot in ipairs(slots) do
    for _,limit in ipairs(PROVISIONS.options.limits) do
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
        table.insert(sources, s)
      end
    elseif s.is_dest then
      found_dests = true
      if (s.limit or stack_sizes_cache[s.name] or 64) > s.count then
        table.insert(dests, s)
      end
    end
  end

  if PROVISIONS.just_listing then
    -- TODO: options on how to aggregate
    local listing = {}
    for _,slot in pairs(sources) do
      listing[slot.name] = (listing[slot.name] or 0)+slot.count
    end
    PROVISIONS.output = listing
    return
  end

  if not found_dests or not found_sources then
    if not found_sources then
      if not found_dests then
        latest_warning = "Warning: No sources nor destinations found."
      else
        latest_warning = "Warning: No sources found.                 "
      end
    else
      latest_warning = "Warning: No destinations found.            "
    end
    -- yield to prevent timing out from not doing anything
    sleep(0)
    return
  end

  PROVISIONS.hoppering_stage = "sort"
  sort_sources(sources)
  sort_dests(dests)
  local dests_lookup = generate_dests_lookup(dests)

  PROVISIONS.hoppering_stage = "transfer"

  -- begin a self->self transfer session (if the computer is a turtle)
  -- hopper_loop has the job of ending it by calling :destructor()
  PROVISIONS.myself:begin_transfer_session()

  for si,s in ipairs(sources) do
    if s.name ~= nil and matches_filters(s) then
      local sw = willing_to_give(s)
      local ident = nil
      local iteration_mode = "begin" -- "begin", "partial", "empty", or "done"
      local dii = nil
      while true do
        if sw == 0 then break end
        if s.transfer_strikes >= transfer_strike_out then break end
        if iteration_mode == "done" then break end
        if not dii then
          if iteration_mode == "begin" then
            iteration_mode = "partial"
            ident = slot_identifier(s, PROVISIONS.options.preserve_slots)
            if dests_lookup[ident] then
              dii = dests_lookup[ident].s
            end
          elseif iteration_mode == "partial" then
            iteration_mode = "empty"
            ident = empty_slot_identifier(s, PROVISIONS.options.preserve_slots)
            if dests_lookup[ident] then
              dii = dests_lookup[ident].s
            end
          else
            iteration_mode = "done"
            break
          end
        elseif dii > dests_lookup[ident].e then
          dii = nil
        else
          local di = dests_lookup[ident].slots[dii]
          local d = dests[di]
          if (d.name ~= nil and d.name ~= s.name) or d.type ~= s.type then
            error("BUG DETECTED! dests_lookup inconsistency: "..s.chest_name..":"..s.slot_number..":"..(s.type or "").." -> "..d.chest_name..":"..d.slot_number..":"..(d.type or ""))
          end
          local dw = willing_to_take(d, s)
          if dw == 0 and d.name ~= nil then
            -- remove d from list of destinations
            if dii == dests_lookup[ident].s then
              dests_lookup[ident].slots[dii] = nil
              dests_lookup[ident].s = dests_lookup[ident].s+1
            else
              table.remove(dests_lookup[ident].slots, dii)
              dests_lookup[ident].e = dests_lookup[ident].e-1
            end
          end
          local to_transfer = math.min(sw, dw)
          to_transfer = to_transfer-(to_transfer%(PROVISIONS.options.batch_multiple or 1))
          if to_transfer < (PROVISIONS.options.min_batch or 0) then
            to_transfer = 0
          end
          if to_transfer > 0 then
            if remote_names[s.chest_name] and remote_names[d.chest_name] then
              if remote_names[s.chest_name] ~= remote_names[d.chest_name] then
                error("cannot transfer between "..s.chest_name.." and "..d.chest_name.." as they're on separate networks!")
              end
            end

            -- FIXME: propagate errors up correctly

            -- TODO: add a warning for when transfer returns nil
            -- TODO: use stubbornly() in transfer() as well
            local transferred = transfer(s, d, to_transfer) or 0

            if transferred ~= to_transfer then
              -- either the source or the dest are to blame for this
              -- as we cannot know which just from a single transfer
              -- we keep a score of how many times a slot has
              -- participated in a failed transfer.
              -- 3 strikes and it's out
              if transferred == 0 then
                s.transfer_strikes = s.transfer_strikes+1
                d.transfer_strikes = d.transfer_strikes+1
              end

              -- is the failure expected? (aka. should we raise a warning)
              local failure_unexpected = true
              if (d.type or "i") == "i" and isUPW(d.chest_name) then
                -- the UPW api doesn't give us any indication of how many items an inventory can take
                -- therefore the only way to transfer items is to just try and see if it succeeds
                -- thus, failure is expected.
                failure_unexpected = false
              elseif (d.type or "i") == "i" and isMEBridge(s.chest_name) then
                -- the AdvancedPeripherals api doesn't give us maxCount
                -- so this error is part of normal operation
                failure_unexpected = false
              elseif s.type == "f" then
                -- fluid api doesn't give us inventory size either.
                failure_unexpected = false
              end
              if failure_unexpected then
                -- latest_error = "transferred too little, retrying"
                latest_warning = "WARNING: transferred less than expected: "..s.chest_name..":"..s.slot_number.." -> "..d.chest_name..":"..d.slot_number
              end
            end

            local transferred_hook_info = nil
            if PROVISIONS.logging.transferred and (transferred > 0 or PROVISIONS.global_options.debug) then
              -- we just prepare the info here (because it's easier)
              -- the hook is instead called after we finish updating
              -- the internal slot information
              -- (in case the hook hangs or errors)
              transferred_hook_info = {
                transferred = transferred,
                from = s.chest_name,
                to = d.chest_name,
                name = s.name,
                displayName = display_name_cache[s.name..";"..(s.nbt or "")],
                nbt = s.nbt or "",
                type = s.type or "i",
              }
            end

            s.count = s.count-transferred
            d.count = d.count+transferred
            if transferred > 0 then
              -- relevant if d was empty
              d.name = s.name
              d.nbt = s.nbt

              if d.dest_after_action then
                d.dest_after_action(d, s, transferred)
              end
            end
            -- relevant if s became empty
            if s.count == 0 then
              if s.type ~= "e" then
                s.name = nil
                s.nbt = nil
              end
              -- s.limit = 1/0
            end

            if d.count == transferred and transferred > 0 then
              -- slot is no longer empty
              -- we have to add it to the partial slots index (there might be more source slots of the same item type)
              local d_ident = slot_identifier(d, PROVISIONS.options.preserve_slots)
              if not dests_lookup[d_ident] then
                dests_lookup[d_ident] = {slots = {}, s = 1, e = 0}
              end
              dests_lookup[d_ident].s = dests_lookup[d_ident].s-1
              dests_lookup[d_ident].slots[dests_lookup[d_ident].s] = di

              -- and we have to remove it from the empty slots index
              if not d.duplicate then
                if dii == dests_lookup[ident].s then
                  dests_lookup[ident].slots[dii] = nil
                  dests_lookup[ident].s = dests_lookup[ident].s+1
                else
                  table.remove(dests_lookup[ident].slots, dii)
                  dests_lookup[ident].e = dests_lookup[ident].e-1
                end
              else
                -- ...except we don't!
                -- we instead need to replace it with a new empty slot of the same type
                local newd = duplicate_slot(d)
                d.duplicate = nil
                table.insert(dests, newd)
                dests_lookup[ident].slots[dii] = #dests
              end
            end

            if d.transfer_strikes >= transfer_strike_out then
              -- slot is bad, remove it from the indexes completely
              if dii == dests_lookup[ident].s then
                dests_lookup[ident].slots[dii] = nil
                dests_lookup[ident].s = dests_lookup[ident].s+1
              else
                table.remove(dests_lookup[ident].slots, dii)
                dests_lookup[ident].e = dests_lookup[ident].e-1
              end
            end

            PROVISIONS.report_transfer(transferred)
            for _,limit in ipairs(PROVISIONS.options.limits) do
              inform_limit_of_transfer(limit, s, d, transferred)
            end

            sw = willing_to_give(s)

            if transferred_hook_info then
              PROVISIONS.logging.transferred(transferred_hook_info)
            end
          end

          dii = dii+1
        end
      end
    end
  end
end

local function hopper_loop(commands)
  local time_to_wake = nil
  while true do
    for _,command in ipairs(commands) do
      local from = command.from
      local to = command.to
      if not from then
        error("no 'from' parameter supplied!")
      end
      if not to then
        error("no 'to' parameter supplied! ('from' is "..from..")")
      end


      local provisions = {
        options = command.options,
        filters = command.filters,
        chest_wrap_cache = {},
        scan_task_manager = TaskManager:new(PROVISIONS.global_options.scan_threads),
        myself = Myself:new(),
      }
      local success, error_msg = provide(provisions, function()
        return pcall(hopper_step, command.from, command.to)
      end)
      PROVISIONS.hoppering_stage = nil
      provisions.myself:destructor()

      if not success then
        latest_error = error_msg
        if PROVISIONS.global_options.once then
          error(error_msg, 0)
        end
      else
        latest_error = latest_warning
      end
    end

    if PROVISIONS.global_options.once then
      break
    end

    local current_time = os.clock()
    time_to_wake = (time_to_wake or current_time)+PROVISIONS.global_options.sleep

    sleep(time_to_wake-current_time)
  end
end


local function hopper_main(args, is_lua, just_listing, logging)
  local args_string = "{"..type(args).."}"
  if type(args) == "string" then
    args = args:gsub("\n$", "")
    args_string = args
  end
  local commands, global_options = parser(args, is_lua)
  local total_transferred = 0
  local provisions = {
    global_options = global_options or {},
    is_lua = is_lua or false,
    just_listing = just_listing or false,
    hoppering_stage = undefined,
    report_transfer = function(transferred)
      total_transferred = total_transferred+transferred
      return total_transferred
    end,
    output = undefined,
    start_time = global_options.quiet or os.clock(),
    logging = logging or {},
  }
  local function displaying()
    display_loop(args_string)
  end
  local function transferring()
    hopper_loop(commands)
  end
  local terminated
  provide(provisions, function()
    terminated = exitOnTerminate(function()
      parallel.waitForAny(transferring, displaying)
    end)
    display_exit(args_string)
  end)
  if just_listing then
    return provisions.output
  elseif terminated and is_lua then
    error(terminated, 0)
  else
    return total_transferred
  end
end

local function hopper_list(chests)
  return hopper_main(chests.." void", true, true, {})
end

local function hopper(args, logging)
  return hopper_main(args, true, false, logging)
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

  if is_imported then
    local exports = {
      hopper = hopper,
      version = version,
      list = hopper_list,
    }
    setmetatable(exports, {
      __call = function(self, ...) return self.hopper(...) end,
      debug = {
        is_inventory = function(chest) return is_inventory(chest) end,
        chest_list = function(chest, options)
          return provide({
              chest_wrap_cache = {},
              options = options or {},
              scan_task_manager = TaskManager:new(8),
            },
            function()
              return chest_wrap(chest).list()
            end
          )
        end,
      },
    })
    return exports
  end

  if #args <= 0 then
    print(help_message)
    return
  end

  local args_string = table.concat(args, " ")
  hopper_main(args_string)
end

return main
