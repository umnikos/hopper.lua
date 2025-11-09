# Specifying slots

By default hopper.lua will take items from any slot and place items into any slot, but this can be changed by specifying particular slot numbers to use:
- `-from-slot [number]` - Specify a single slot number to take items from
- `-from-slot-range [from_number] [to_number]` - Specifies an entire range of slots to pull from (including the start and end slots)
- `-to-slot [number]` - Specify a single slot number to push items to
- `-to-slot-range [from_number] [to_number]` - Specifies an entire range of slots to push to (including the start and end slots)
- `-preserve-order`/`-preserve-slots` - Will only do a transfer if the source and destination slots have the same slot number. Useful for avoiding item shuffling during transfers from chest to chest.

Multiple slots and slot ranges can be specified, in which case it will simply use all of the specified slots

Additionally, negative slot indexes are valid and count backwards instead of forwards (-1 is the last slot, -2 is the second-to-last slot, etc.)

Examples:

`hopper *barrel* *chest* -from-slot-range 1 18 -to-slot 1 -to-slot 3 -to-slot 5` - Move items only from the first 18 slots of the barrels and only into slots 1, 3 and 5 of the chests

`hopper *barrel* *chest* *sapling* -from-slot-range 2 -1` - Move saplings from the barrels and into the chests, but not saplings that are in the first slot of a barrel.

`hopper *chest*|*barrel* *brewing_stand* *:blaze_powder -to-slot 5 -to-limit 1 -per-slot` - Keep connected brewing stands constantly fed with blaze powder, not keeping more than 1 extra powder in each stand
