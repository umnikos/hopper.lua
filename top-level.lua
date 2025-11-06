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
-- new special casing for:
-- - create processing blocks
-- - powah energizing orb
-- table api filters now support all,any,none logical operators
-- implemented transfer strikes system: if a slot is part of 3 failed operations it is ignored for the rest of the transfer
-- integration with UPW network manager (example: `hopper group:hi group:bye`)
-- -slots/-stacks modifier for limits

local function using(s, name)
  local f, err = load(s, name, nil, _ENV)
  if not f then
    error(err, 0)
  end
  return f()
end
