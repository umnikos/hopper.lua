#!/usr/bin/env nu

# hopper.lua build script
# combines til.lua and hopper_source.lua into hopper.lua

# written for nushell 0.107.0 (but should probably work with later versions)

def fetch-file [name: string, url: string, hash: string] {
  cd libs
  touch $name
  if ((open $name | hash sha256) != $hash) {
    print $"Fetching ($name)..."
    http get $url | save $name -f
  }
  if ((open $name | hash sha256) != $hash) {
    error make {msg: $"Could not fetch ($name): hash mismatch"}
  }
}


def fetch-dependencies [] {
  mkdir libs
  fetch-file til.lua https://raw.githubusercontent.com/umnikos/til/94d70f2e50155a83699778d6da8e3fc04a368f7c/til.lua ed5bd49ebaef49dc1a437fa0e999bd8b3159d4df2a19f18ae61f253a1851bd0a
}

def build [] {
  print (date now | format date "%T") -n
  print " - Building... " -n

  fetch-dependencies

  let main_source = open src/main.lua
  let til_source = open libs/til.lua

  let hopper = $"
local main
local til
main = load\([==[--main.lua     ($main_source)]==],nil,nil,_ENV\)\(\)
til = load\([==[--til.lua     ($til_source)]==],nil,nil,_ENV\)\(\)
return main\({...}\)"

  rm --force hopper.lua
  $hopper | save hopper.lua
  chmod -w hopper.lua # prevent accidental editing of the built file

  print "Built hopper.lua"
}

def autobuild [] {
  build
  watch . --glob "src/*.lua" {|| build } -q
}

def main [--loop] {
  if $loop {
    autobuild
  } else {
    build
    print "Done."
  }
}

