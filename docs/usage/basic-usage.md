# Basic usage

To simply move all the items from somewhere to somewhere else, you can run `hopper [source] [destination]` 

Example: `hopper left right` will continuously move any items from the chest on the left of the computer to the chest on the right of the computer

The source and destination parameters also support wildcards

Example: `hopper *chest* *barrel*` will move any items from any connected chest to any connected barrel

If you only want to move some kinds of items, you can add item name filters after the source and the destination: `hopper [source] [destination] {[filter]}*`

Example: `hopper left right minecraft:iron_ingot minecraft:gold_ingot` will only move iron and gold ingots from the left chest to the right one, and will ignore all other items

Item names also support wildcards

Example: `hopper left right *_ingot` will move any items whose name ends in `_ingot` from the left chest to the right one

Item tags are also supported, and are done using `$`

Example: `hopper left right $c:ingots` will move any ingots from the left chest to the right one, including things like `create:andesite_alloy`

You can specify multiple sources or destinations by separating them with `|`

Example: `hopper left|right top|bottom` will move anything from the left and right chests to the top and bottom ones.

Priority is given to whichever chest appears sooner in the match.

Example: `hopper top right|bottom` will move items from the top to the right if it can, but if the chest on the right is full or missing it will move items down instead

## Setting up pipelines
If you just run a hopper command from the terminal directly it'll stop running the moment the computer reboots (just like how any other program would).
In order to have your command run persistently you must place it in a file called `startup.lua` like so:

`startup.lua`
```lua
shell.run("hopper left right")
```

To confirm you did it correctly simply reboot the computer and you should see the supplied hopper command running.

You can also use `[[` and `]]` to delimit a multi-line string, which is useful for longer commands:

`startup.lua`
```lua
shell.run([[
  hopper left right
]])
```

On an advanced computer you can use `shell.openTab` instead of `shell.run` to have it run in a separate tab

## Where next

For more advanced usage read [the rest of the wiki pages](/docs/usage/). If you are experiencing problems first visit the [Physical setup](/docs/usage/physical-setup.md) page and if that doesn't help consider [making an issue](https://github.com/umnikos/hopper.lua/issues)
