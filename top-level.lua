-- Copyright umnikos (Alex Stefanov) 2023-2025
-- Licensed under MIT license

local _ENV = setmetatable({}, {__index = _ENV})

version = "v1.5 ALPHA{timemark}"

help_message = [[
hopper.lua ]]..version..[[, made by umnikos

example usage:
  hopper *chest* *barrel* -not *:pink_wool

documentation & bug reports:
  https://github.com/umnikos/hopper.lua]]

-- v1.5 changelog:
-- -storage has been rewritten
-- special casing for create processing blocks

local function using(s, name)
  local f, err = load(s, name, nil, _ENV)
  if not f then
    error(err, 0)
  end
  return f()
end
