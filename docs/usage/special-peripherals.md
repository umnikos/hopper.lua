# Special peripherals

As an abstraction over cc inventory methods, hopper.lua can afford to simplify the way existing peripherals work and to add a few more useful peripheral names to the roster.

### 0. Fluids and energy transer
Fluids are supported and work like items. 1 millibucket of fluid counts as 1 item.

If a recent enough version of the UnlimitedPeripheralWorks mod is installed (and configured properly) energy is also transferable. Use `-energy` to switch from transferring items and fluids to transferring energy. 1 unit of energy counts as 1 item. Currently the source and destination must work with the same energy unit (aka. energy conversion is not supported)

### 1. `self` peripheral for turtles

If hopper.lua is ran on a turtle that is connected to a wired modem, the `self` peripheral name will be present and will represent the turtle's own inventory (16 slots). It can then transfer items to and from any chests connected to that wired modem

Example: `hopper *chest* self *iron_ingot* -to-slot 1 -to-slot 3 -to-slot 6 -to-limit 16 -per-slot` - Transfer iron ingots from a connected chest to the turtle's inventory in the shape of a bucket, in preparation for crafting buckets with `turtle.craft()`

### 2. AE2 networks
On fabric with UnlimitedPeripheralWorks, connect an energy cell (yes, an energy cell) to a modem to access the whole network's items and fluids.

On forge with Advanced Peripherals, connect an ME Bridge to a modem to access the whole network's items. (fluids are not yet supported)

### 3. Disk drive peripheral

Any items hoppered into a disk drive will immediately be ejected out of it, essentially making it a more powerful dropper.

Example: `hopper *chest* *drive* *cobble*` - send cobblestone and its relatives to be dropped into lava

### 4. `void`

_The void is an infinite hole that consumes all that you give it and yet remains entirely empty._ Or well, it would be if it existed. This is an imaginary peripheral that _pretends_ to throw away all of your items, and instead just counts how many it would've thrown away if it did, obeying things like `-from-limit` and `-transfer-limit`. This count can then be used if you're calling hopper.lua using the library api. 

Example: If when you call `hopper("self void")` it returns 18, you can conclude from it that there are a total of 18 items in the turtle's inventory

### 5. Bound introspection module in a manipulator

Supplying the peripheral name of a manipulator with a bound introspection module in it will act as the inventory of the player the module is bound to (36 slots) or their ender chest if `-ender` is passed as a flag (27 slots). If the player is offline it will instead represent a chest with 0 slots, and thus no transfers to and from it will be attempted.

Example: `hopper *chest* *manipulator* *steak* -to-slot 9` - Keep the last slot in your hotbar constantly full of steak to eat


