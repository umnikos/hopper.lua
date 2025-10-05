-- simple task manager
-- a wrapper over parallel.waitForAll
-- that allows for rate limiting
-- and easy results collection
local TaskManager = {}
function TaskManager:new(max_active_threads)
  local new_manager = {
    max_active_threads = max_active_threads or 8,
    active_threads = 1,
  }
  self.__index = self
  setmetatable(new_manager, self)
  return new_manager
end

-- accepts a list of tasks to run (which can themselves spawn more tasks)
-- returns the result of each (in a list ordered the same way, packed)
function TaskManager:await(l)
  local results = {}
  local threads = {}
  for i = 1,#l do
    table.insert(threads, function()
      while self.active_threads >= self.max_active_threads do coroutine.yield() end
      self.active_threads = self.active_threads+1
      results[i] = l[i]()
      self.active_threads = self.active_threads-1
    end)
  end
  self.active_threads = self.active_threads-1
  parallel.waitForAll(table.unpack(threads))
  self.active_threads = self.active_threads+1
  return results
end

return TaskManager
