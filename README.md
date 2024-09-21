# hopper.lua
The ffmpeg of minecraft item transportation: move items from A to B without any hassle.

## What is this?
A high-level abstraction over the raw CC inventory API.
It unifies the many ways different inventory APIs into a consistent interface, and 
said interface includes a wide range of options for quickly and easily setting up both simple and complicated item pipelines.
It is powerful, high-throughput, easy to use, flexible, and not very lag-inducing.

As an example use, here's all of the code needed for a super smelter (aka. a furnace array):

`startup.lua`

```lua
shell.openTab([[hopper -sleep 5
  -alias input *chest*
  -alias fuel *chest*
  -alias bucketreturn *barrel*
  -alias output *barrel*
  / input *furnace* -not *:lava_bucket -to_slot 1 -to_limit 5 -per_chest
  / fuel *furnace* *:lava_bucket -to_slot 2
  / *furnace* bucketreturn *:bucket -from_slot 2 
  / *furnace* output -from_slot 3
]])
```

## Installation

### Latest release

Run these two commands on your CC computer to fetch the code:
```
cd /
wget https://raw.githubusercontent.com/umnikos/hopper.lua/main/hopper.lua
```

### Beta version

To get the newest bugs and features, fetch the code from the beta branch:
```
wget https://raw.githubusercontent.com/umnikos/hopper.lua/beta/hopper.lua
```

## Usage

Consult [the wiki](https://github.com/umnikos/hopper.lua/wiki/Basic-usage) for a tutorial on how to get started. It currently also doubles as documentation.
