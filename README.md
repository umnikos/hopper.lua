# hopper.lua
The ffmpeg of minecraft item transportation: move items (and fluids!) from A to B without any hassle.

## What is this?
A replacement for all of your pipes, belts, conduit cables, funnels, filters, and more.
Hopper.lua does two things:
- It unifies all of the various underlying CC inventory APIs into a single, consistent interface
- Said interface is high-level, making it quick and easy to set up various pipelines, and is useful both for simple and for complicated jobs

For those familiar with [SFM](https://www.curseforge.com/minecraft/mc-mods/super-factory-manager), hopper.lua provides a very similar set of features to that mod.

As an example use, here's all of the code needed for a furnace array (aka. a super smelter):

`startup.lua`

```lua
shell.run([[hopper -sleep 5
  -alias input *chest*
  -alias fuel *chest*
  -alias bucket_return *barrel*
  -alias output *barrel*
  / input *furnace* -not *:lava_bucket -to_slot 1 -to_limit 5 -per_chest
  / fuel *furnace* *:lava_bucket -to_slot 2
  / *furnace* bucket_return *:bucket -from_slot 2 
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
