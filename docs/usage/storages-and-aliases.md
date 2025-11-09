# Storages and aliases

## `-alias`
Aliases are a way to assign a new name to a set of peripherals. This makes commands more readable (`hopper in out` instead of `hopper *chest*_3945 *barrel*_2239`) and more maintainable (if you move one of the chests you only need to change the name in the alias and can leave the rest of the commands untouched). Any peripherals can be aliased, and one peripheral can be part of multiple aliases. You can also use aliases in the definitions of further aliases (but not in the definitions of previous aliases, so the order matters).

Example: `hopper -alias in *chest*_3945 -alias out *barrel*_2239 in out` - Equivalent to `hopper *chest*_3945 *barrel*_2239`. Not really more readable because the alias definitions only made the command longer.

Example with multiline syntax (in general `-alias` is most useful with the multiline syntax):
```lua
shell.openTab([[hopper
  -alias in *chest*_3945
  -alias out *barrel*_2239
  / in out -from-slot 1 -to-slot 5
  / in out -from-slot 5 -to-slot 1
  / in out -from-slot_range 2 4 -preserve-order
]])
```

Alias names can only include letters and underscores (aka. cannot include numbers or other special characters). Alias names are case-sensitive.

Example: `-alias aAaAa *chest*` and `-alias a_thing *chest*` are both valid, but `-alias a-thing *chest*` is not.

## `-storage`
Identical syntax to `-alias` but with a completely different purpose. Whereas aliases are just shorthands, `-storage` is for setting up an array of chests for storing bulk amounts of items. The chests, crucially, are *not* going to be rescanned over and over, as the assumption is that only hopper.lua will ever put items in and take items out of the chests.

The following requirements must be met before you can use `-storage`:
1. Nothing other than a single hopper.lua instance should ever put items in or takes items out of the wrapped chests. That includes players, redstone, other programs, and other hopper.lua instances.
  - If that ever happens, restart the hopper.lua instance in order to force it to rescan the storage and thus fix its internal cache.
  - To avoid such accidents, all chests that get wrapped into a storage are no longer individually accessible in the hopper.lua instance.
2. The wrapped chests must be generic inventories (chests, vanilla barrels, etc.). Turtles, introspection modules, the void, and other weird or picky peripherals are not supported.

Example: A very simple bulk storage setup, one chest acts as input and another one as output. This is useful for quickly setting up buffers for farms that see irregular production and/or irregular demand.
```lua
shell.openTab([[hopper -sleep 5
  -alias in *chest*_5938
  -alias out *chest*_5939
  -storage store *barrel*
  / in store
  / store out
]])
```
