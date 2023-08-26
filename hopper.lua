local args = {...}
if #args < 2 then
    print("usage: hopper {from} {to} [{item name}]")
    return
end
local from = args[1]
print("hoppering from "..from)
local to = args[2]
print("to "..to)
local filter = args[3]
if filter then
print("only the item "..filter)
end
while true do
  local chest = peripheral.wrap(from)
  chestlist = chest.list()
  for i=1,chest.size() do
    if chestlist[i] and (filter == nil or chestlist[i].name == filter) then
      chest.pushItems(to,i)
    end
  end
  sleep(1)
end