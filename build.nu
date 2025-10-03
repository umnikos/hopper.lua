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

  mut output = ""

  mut sources = []
  for dir in [src, libs] {
    $sources = $sources | append (ls $dir | get name)
  }
  mut names = []
  for source in $sources {
    # WARNING: do not name two different files the same thing! the path information is lost here
    let name = $source | path basename | str replace ".lua" ""
    if $name in $names {
      error make -u {msg: $"DUPLICATE FILE NAME: ($name)"}
    } else {
      $names = $names | append $name
    }
    $output = $output + $"local ($name)\n"
  }
  for source in $sources {
    let name = $source | path basename | str replace ".lua" ""
    let code = open $source
    $output = $output + $"($name) = load\([==[($code)]==],'($name).lua',nil,_ENV\)\(\)\n"
  }

  $output = $output + "return main\({...}\)\n"

  rm --force hopper.lua
  $output | save hopper.lua
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

