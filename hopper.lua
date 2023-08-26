-- Copyright umnikos (Alex Stefanov) 2023
-- Licensed under MIT license
-- Version 1.1

function noop()
end

function glob(p, s)
  local p = "^"..string.gsub(p,"*",".*").."$"
  local res = string.find(s,p)
  return res ~= nil
end


function hopper(from,to,filters,options)
  if not options then
    options = {}
  end
  if not filters then
    filters = {}
  end
  if type(filters) == "string" then
    filters = {filters}
  end

  local print = print
  if options.quiet then
    print = noop
  end
  
  local sources = {}
  local destinations = {}
  for i,per in ipairs(peripheral.getNames()) do
    if glob(from,per) then
      sources[#sources+1] = per
    end
    if glob(to,per) then
      destinations[#destinations+1] = per
    end
  end
  print("hoppering from "..from)
  if options.from_slot then
    print("and only from slot "..tostring(options.from_slot))
  end
  if #sources == 0 then
    print("except there's nothing matching that description!")
    return
  end
  print("to "..to)
  if #destinations == 0 then
    print("except there's nothing matching that description!")
    return
  end
  if options.to_slot then
    print("and only to slot "..tostring(options.to_slot))
  end

  if #filters == 1 then
    print("only the items matching the filter "..filters[1])
  elseif #filters > 1 then
    print("only the items matching any of the filters")
  else
    filters[1] = "*"
  end

  -- I promise to clean this mess in v1.2
  -- (please hold me accountable to that, too)
  while true do
    for _,source_name in ipairs(sources) do
      if (not glob(to,source_name)) or (options.to_slot and options.from_slot and options.from_slot ~= options.to_slot) then
        local source = peripheral.wrap(source_name)
        for _,dest_name in ipairs(destinations) do
          local dest = peripheral.wrap(dest_name)
          local source_list = source.list()
          local dest_list = dest.list()
          for i=1,source.size() do
            if options.from_slot then
              i = options.from_slot
            end
            for _,filter in ipairs(filters) do
              if source_list[i] and glob(filter,source_list[i].name) then
                --print("pushing items")
                local max = nil
                if options.to_limit then
                  dest_list = dest.list()
                  local dest_count = 0
                  for j=1,dest.size() do
                    if options.to_slot then
                      j = options.to_slot
                    end
                    if dest_list[j] and glob(filter,dest_list[j].name) then
                      dest_count = dest_count + dest_list[j].count
                    end
                    if options.to_slot then
                      break
                    end
                  end
                  max = options.to_limit - dest_count
                end
                if options.from_limit then
                  source_list = source.list()
                  local source_count = 0
                  for j=1,source.size() do
                    if options.from_slot then
                      j = options.from_slot
                    end
                    if source_list[j] and glob(filter,source_list[j].name) then
                      source_count = source_count + source_list[j].count
                    end
                    if options.from_slot then
                      break
                    end
                  end
                  local max_from = source_count - options.from_limit
                  if not max or max > max_from then
                    max = max_from
                  end
                end
                source.pushItems(dest_name,i,max,options.to_slot)
              end
            end
            if options.from_slot then
              break
            end
          end
        end
      end
    end
    if options.once then
      break
    end
    sleep(1)
  end

end


local args = {...}

if args[1] == "hopper" then
  return hopper
end

local help_message = [[
hopper script v1.1, made by umnikos

usage: hopper {from} {to} [{item name}/{flag}]*
example: hopper *chest* *barrel* *:pink_wool
flags:
  -once : run the script only once instead of in a loop
  -forever: run the script in a loop forever (default)
  -quiet: print less things to the terminal
  -verbose: print everything to the terminal (default)
  -from_slot [slot]: restrict pulling to a single slot
  -to_slot [slot]: restrict pushing to a single slot
  -from_limit [num]: keep at least this many matching items in every source chest
  -to_limit [num]: fill every destination chest with at most this many matching items]]
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