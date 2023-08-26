-- Copyright umnikos (Alex Stefanov) 2023
-- Licensed under MIT license
-- Version 1.0

local args = {...}

local help_message = [[
hopper script v1.0, made by umnikos

usage: hopper {from} {to} [{item name}/{flag}]*
example: hopper *chest* *barrel* *:pink_wool
flags:
  -once : run the script only once instead of in a loop]]
if #args < 2 then
    print(help_message)
    return
end
local from = args[1]
local to = args[2]
local sources = {}
local destinations = {}
function glob(p, s)
  local p = "^"..string.gsub(p,"*",".*").."$"
  local res = string.find(s,p)
  return res ~= nil
end
for i,per in ipairs(peripheral.getNames()) do
  if glob(from,per) then
    sources[#sources+1] = per
  end
  if glob(to,per) then
    destinations[#destinations+1] = per
  end
end
print("hoppering from "..from)
if #sources == 0 then
  print("except there's nothing matching that description!")
  return
end
print("to "..to)
if #destinations == 0 then
  print("except there's nothing matching that description!")
  return
end
local filters = {}
local once = false
for i=3,#args do
  if glob("-*",args[i]) then
    if args[i] == "-once" then
      print("(only once!)")
      once = true
    end
  else
    filters[#filters+1] = args[i]
  end
end
if #filters == 1 then
  print("only the items matching the filter "..filters[1])
elseif #filters > 1 then
  print("only the items matching any of the filters")
else
  filters[1] = "*"
end
while true do
  for _,source_name in ipairs(sources) do
    if not glob(to,source_name) then
      local source = peripheral.wrap(source_name)
      for _,dest_name in ipairs(destinations) do
        source_list = source.list()
        for i=1,source.size() do
          for _,filter in ipairs(filters) do
            if source_list[i] and glob(filter,source_list[i].name) then
              --print("pushing items")
              source.pushItems(dest_name,i)
            end
          end
        end
      end
    end
  end
  if once then
    break
  end
  sleep(1)
end