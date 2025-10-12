-- Copyright umnikos (Alex Stefanov) 2023-2025
-- Licensed under MIT license

local _ENV = setmetatable({}, {__index = _ENV})

version = "v1.4.5"

help_message = [[
hopper.lua ]]..version..[[, made by umnikos

example usage:
  hopper *chest* *barrel* -not *:pink_wool

documentation & bug reports:
  https://github.com/umnikos/hopper.lua]]

-- v1.4.5 changelog:
-- turtle transfers with UnlimitedPeripheralWorks
-- faster .list() with UnlimitedPeripheralWorks
-- energy transfer with -energy and UnlimitedPeripheralWorks
-- tag-based filtering: `hopper left right $c:ores`
-- table-based lua api
-- special casing for apotheosis library

local function using(s, name)
  local f, err = load(s, name, nil, _ENV)
  if not f then
    error(err, 0)
  end
  return f()
end
