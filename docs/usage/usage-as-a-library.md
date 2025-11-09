# Using hopper.lua as a library

## Basic usage

Hopper.lua can be used within scripts by importing the file as a library. This will give you a function called `hopper`, which accepts an arguments string with the exact same syntax as the command line interface. This is better than using `shell.run()` to call hopper.lua because it allows for caching various data and thus way faster transfer. The function passes `-once -quiet` by default, use `-forever` if you want to override `-once`.

Usage of storages and aliases is also supported. Simply use `-storage` or `-alias` in a command and the definition will be remembered for all further commands.

Example program to autocraft buckets: (Chest `ender_storage_6958` is full of iron ingots and chest `ender_storage_6959` is where the finished buckets should go. The program is written in such a way as to not break if the turtle randomly gets rebooted or the source chest runs out of iron ingots)

```lua
local hopper = require("hopper")

-- setup aliases for convenience
hopper("-alias iron *storage*_6958")
hopper("-alias output *storage*_6959")

turtle.select(16)
while true do
  -- fill inventory with iron
  hopper("iron self *:iron_ingot -to-slot 1 -to-slot 3 -to-slot 6 -to-limit 16 -per-slot")
  -- check how many slots have at least 1 iron ingot in them
  local count = hopper("self void *:iron_ingot -transfer-limit 1 -per-slot")
  if count >= 3 then
    -- all is good, craft!
    turtle.craft(16)
  end
  -- regardless of success, output the buckets
  hopper("self output *bucket* -to-slot-range 1 9")
  sleep(1)
end
```

## Intermediate usage

### Listing
`hopper.list()` exists for conveniently fetching the contents of a set of inventories.

Example:
```lua
local hopper = require("hopper")
local amounts = hopper.list("*chest*")
print(amounts["minecraft:cobblestone"])
```
This is currently less flexible than hoppering into `void`, but it lets you get an entire list of amounts instead of just a single number.

### Logging
As a second argument to `hopper()` you can pass a table of logging functions which will be called as hopper.lua runs. Currently the only hook that exists is the `transferred` function field, which is called every time a successful transfer happens and is given information about said transfer

Example: The following code is just `hopper left right` but will print out information about every individual item transfer to the terminal
```lua
local hopper = require("hopper")
local pprint = require("cc.pretty").pretty_print
local logging = {
  transferred = pprint
}
hopper("left right", logging)
```

## Advanced usage

Instead of passing a string to `hopper()` it's possible to pass a table describing the desired operation. This is mostly useful for programmatic query construction as it's less convenient but more structured when compared to passing a string.

The following is a description of the table-based api as of v1.4.5, written in the style of TypeScript code:

```ts
function hopper(commands: CommandList, logging?: LoggingHooks)
type CommandList = Command[] | Command
type Command = string | { 
  from: string,
  to: string,
  filters?: Filters,
  limits?: Limits,
  from_slot?: SlotSpecifier,
  to_slot?: SlotSpecifier,
  once?: boolean,
  // most flags can be used through this api by using
  // their name as the key and then a list of arguments as the value  
  // if the flag doesn't normally have an argument just pass in a dummy value
  [flagname: string]: (string | number)[] | string | number, 
}
type Filters = Filter[] | Filter
type Filter = string | FilterTable | FilterFunction
type FilterTable = {
  // at least one of these must be supplied
  // supplying multiple of these "and"s them together
  name?: string,
  nbt?: string,
  tag?: string, // *without* the "$" at the start
}
type FilterFunction = (FilterFunctionInformation) => boolean
type FilterFunctionInformation = {
  chest_name: string,
  chest_size: number | nil, // output of .size() if such a method exists
  slot_number: number, // 0 if there's none
  name: string,
  nbt: string, // "" if there's no nbt data or if the data is unknown and assumed to be none
  count: number,
  type: "i" | "f" | "e", // item, fluid, energy
  tags: {[tag: string]: true}, // result of getItemDetail(...).tags
}
type Limits = Limit[] | Limit
type Limit = {
  type: "from" | "to" | "transfer",
  dir?: "min" | "max",
  limit: number,
  per_slot?: boolean,
  per_chest?: boolean,
  per_name?: boolean,
  per_nbt?: boolean,
  count_all?: boolean,
}
type SlotSpecifier = number | (number | NumberRange)[]
type NumberRange = [number, number]

type LoggingHooks = {
  transferred?: (record: TransferRecord) => void,
}
type TransferRecord = {
  transferred: number,
  from: string,
  to: string,
  name: string,
  displayName: string | nil, // nil if the display name is unknown 
  nbt: string, // "" if there's no nbt data or if the data is unknown and assumed to be none
  type: "i" | "f" | "e", // item, fluid, energy
}
```
