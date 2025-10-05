-- Copyright umnikos (Alex Stefanov) 2023-2025
-- Licensed under MIT license

local _ENV = setmetatable({}, {__index = _ENV})

version = "v1.4.5 ALPHA{timemark}"

help_message = [[
hopper script ]]..version..[[, made by umnikos

example usage:
  hopper *chest* *barrel* -not *:pink_wool

for more info check out the repo:
  https://github.com/umnikos/hopper.lua]]

-- v1.4.5 changelog:
-- turtle transfers with UnlimitedPeripheralWorks
-- faster .list() with UnlimitedPeripheralWorks
-- tag-based filtering: `hopper left right $c:ores`
-- table-based lua api

local function using(s, name)
  local f, err = load(s, name, nil, _ENV)
  if not f then
    error(err, 0)
  end
  return f()
end
