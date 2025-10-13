-- if the computer has an inventory (aka. is a turtle)
-- we'd like to be able to transfer to/from it


local Myself = {}
Myself.__index = Myself

function Myself.new()
  local self = {}
  setmetatable(self, Myself)

  self:determine_local_names()

  return self
end

function Myself:determine_local_names()
  -- right after a turtle move there's a slim period of time that
  -- it can wrap modems but isn't connected to them.
  -- this function here provides just enough delay to fix that
  self.modem_count = 0
  self.lookup_table = {}

  if not turtle then return nil end

  turtle.detect()

  local modems = {}
  local modem_names = {}
  local singular_name = nil
  for _,dir in ipairs(sides) do
    local p = peripheral.wrap(dir)
    if p and p.getNameLocal then
      local local_name = p.getNameLocal()
      if local_name then
        self.modem_count = self.modem_count+1
        modems[dir] = p
        modem_names[dir] = local_name
        singular_name = local_name
      end
    end
  end

  if self.modem_count == 1 then
    setmetatable(self.lookup_table, {
      __index = function(t, k) return singular_name end,
    })
  else
    for side,modem in pairs(modems) do
      local sided_name = modem_names[side]
      local chests = modem.getNamesRemote()
      for _,c in ipairs(chests) do
        self.lookup_table[c] = sided_name
      end
    end
  end
end

-- tells you the turtle's peripheral name
-- based on what chest you want to transfer from/to
-- (the turtle might be on multiple networks and thus have multiple names)
function Myself:local_name(chest)
  if not turtle then
    error("Self can only be used from turtles!")
  end
  if self.modem_count == 0 then
    error("No modems were found next to the turtle!")
  end
  local res = self.lookup_table[chest]
  if not res then
    error("BUG DETECTED: failed to determine self when transferring to/from "..chest)
  end
  return res
end

-- these all need to be global so that multiple instances
-- running in parallel can use them
local original_slot
local current_slot
local active_threads = 0
local mutex = false

function Myself:with_mutex(f)
  if self.mutex_held then
    return f()
  end
  while mutex do coroutine.yield() end
  mutex = true
  self.mutex_held = true
  local res = {f()}
  self.mutex_held = false
  mutex = false
  return table.unpack(res)
end

function Myself:save_slot()
  if not turtle then return end
  -- only save if we haven't saved already
  if not original_slot then
    original_slot = turtle.getSelectedSlot()
    current_slot = original_slot
  end
end

function Myself:select(slot)
  if not turtle then return end
  if not original_slot then
    error("BUG DETECTED: tried to switch slots without saving the original one first")
  end
  if current_slot == slot then return end
  self:with_mutex(function()
    local ok = turtle.select(slot)
    if ok then
      current_slot = slot
    end
  end)
end

function Myself:restore_slot()
  if not turtle then return end
  if original_slot and active_threads == 0 then
    self:select(original_slot)
    original_slot = nil
  end
end

function Myself:begin_transfer_session()
  if not turtle then return end
  active_threads = active_threads+1
  self:save_slot()
  self.in_transfer_session = true
end

function Myself:end_transfer_session()
  if not turtle then return end
  if self.in_transfer_session then
    self.in_transfer_session = false
    active_threads = active_threads-1
    self:restore_slot()
  end
end

-- perform a self->self transfer
function Myself:transfer(from, to, count)
  if not turtle then
    error("BUG DETECTED: attempted self->self transfer on a non-turtle")
  end
  if not self.in_transfer_session then
    error("BUG DETECTED: attempted self->self transfer without beginning a transfer session")
  end
  return self:with_mutex(function()
    self:select(from)
    -- this doesn't return how many items were moved
    turtle.transferTo(to, count)
    -- so we'll just trust that the math we used to get `count` is correct
    return count
  end)
end

function Myself:destructor()
  self:end_transfer_session()
end

return Myself
