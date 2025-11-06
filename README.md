# hopper.lua
The ffmpeg of minecraft item transportation: move items and fluids from A to B without any hassle.

## What is this?
A replacement for all of your pipes, belts, fluix cables, funnels, filters, and more.
Hopper.lua does two things:
- It unifies all of the various underlying CC inventory APIs into a single, consistent interface
- Said interface is high-level, making it quick and easy to set up various pipelines, and is useful both for simple and for complicated jobs

For those familiar with [Super Factory Manager](https://www.curseforge.com/minecraft/mc-mods/super-factory-manager), hopper.lua provides a very similar set of features to that mod.

As an example use, here's all of the code needed for a furnace array (aka. a super smelter):

`startup.lua`

```lua
shell.run([[hopper -sleep 5
  -alias input *chest*
  -alias fuel *chest*
  -alias bucket_return *barrel*
  -alias output *barrel*
  / input *furnace* -not *:lava_bucket -to-slot 1 -to-limit 5 -per-chest
  / fuel *furnace* *:lava_bucket -to-slot 2
  / *furnace* bucket_return *:bucket -from-slot 2 
  / *furnace* output -from-slot 3
]])
```

And as a simpler example, here's it cooking some tomato sauce using a Farmer's Delight cooking pot:
```lua
shell.run([[hopper
  / *chest* *pot* *:tomato -to-slot-range 1 2 -to-limit 2 -per-slot
  / *chest* *pot* *:bowl -to-slot 8
  / *pot* *chest* -from-slot 9
]])
```

## Installation

### Latest release

Run these two commands on your CC computer to fetch the code:
```
cd /
wget https://raw.githubusercontent.com/umnikos/hopper.lua/main/hopper.lua
```

### Development version

To get the newest bugs and features, fetch the code from the dev branch:
```
wget https://raw.githubusercontent.com/umnikos/hopper.lua/dev/hopper.lua
```

## Usage

Consult [the wiki](https://github.com/umnikos/hopper.lua/wiki/Basic-usage) for a tutorial on how to get started. It currently also doubles as documentation.
