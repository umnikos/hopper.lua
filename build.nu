#!/usr/bin/env nu

# hopper.lua build script
# combines til.lua and hopper_source.lua into hopper.lua

# written for nushell 0.95.0 (but should probably work with later versions)


def main [] {
  let hopper_source = open hopper_source.lua
  let til_source = open til/til.lua

  let hopper = $"
($hopper_source)
til = load\([==[ ($til_source) ]==]\)\(\)
return main\({...}\)"

  rm --force hopper.lua
  $hopper | save hopper.lua
  chmod -w hopper.lua # prevent accidental editing of the built file
}
