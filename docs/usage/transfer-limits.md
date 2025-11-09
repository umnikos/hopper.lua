# Setting transfer limits

If you want to use hopper.lua to simply keep some chests stocked, or to keep some chests from overflowing, or for a bunch of other reasons, you might want to set a limit on how many items hopper.lua will attempt to transfer.

There are five types of limits:
- `-from-limit [number]`/`-from-limit-min [number]` - Sets a minimum amount of items to keep in the item source, will only take when there's more items than this
- `-from-limit-max [number]` - If the source contains more items than the specified number then nothing will be transferred 
- `-to-limit [number]`/`-to-limit-max [number]` - Sets a maximum amount of items to send to the item destination, will only send when there's less items than this
- `-to-limit-min [number]` - If the destination contains less items than the specified number then nothing will be transferred
- `-transfer-limit [number]` - Sets a limit on how many items can be transferred per iteration, paired with `-sleep` this can be used for rate limiting

The above descriptions are vague on what "the source" and "the destination" are, but that's because this part is configurable as well. By default all matching items in all slots in all the source chests count towards a single unified "number of items" for `-from-limit` to use, but that is not always what you want. The following flags specify other possibilities, and are to be placed after the limit they refer to:

- `-per-chest` - Keeps a separate count for every chest
- `-per-slot` - Keeps a separate count for every slot
- `-per-slot-number` - Keeps a separate count for every slot number (`-per-slot` is equivalent to `-per-chest -per-slot-number`)
- `-per-item` - Keeps a separate count for every item name (ignoring nbt)
- `-per-nbt` - Like `-per-item` but also considers nbt

Multiple of these may be specified for a single limit, for example `-per-chest -per-item` will keep a separate count for every item type in every chest.

Multiple limits may also be specified (even multiple of the same type), in which case hopper.lua will try to satisfy all of them.


Additional options:
- `-count-all` - Include items that did not match the filters into the limit count. Sometimes useful for very complicated logic.
- `-refill` - Alias for `-to-limit-min 1 -per-chest -per-item`. This will essentially make it so that only items of which there's already some of in the destination chest get transferred to that chest 

Examples:

`hopper *barrel* *dispenser* *arrow* -to-limit 20 -per-chest` - Keeps dispensers stocked with arrows from a central set of stock barrels. The amount of arrows per dispenser is kept low in order to not have stacks upon stacks of arrows stuck in potentially unused dispensers.

`hopper *chest* *dropper* *cobblestone* -from-limit 150*64 -per-item -sleep 60` - When connected to some storage system of chests that has more than 150 stacks of cobblestone in it, it will start piping some of that cobblestone to a dropper for disposal purposes. This ensures the storage system won't overflow with cobblestone if you have some quarry connected to it, but that you also don't just throw away all of the cobblestone in case you need some. Since latency isn't important to this operation and your storage may be huge, a delay of 60 seconds ensures this command doesn't cause much lag. (you can also use `-storage` to reduce the amount of lag even further depending on your use case)

`hopper top bottom *diamond* -transfer-limit 1 -sleep 10*60` - This will transfer a single diamond from the top chest to the bottom chest roughly every 10 minutes. If the chest on the bottom is publicly accessible and the top one is not this can be used as a sort of giveaway system

`hopper *chest* *shulker* -refill` - Sort everything from the chests into shulker boxes without having to specify a bunch of filters.

`hopper *chest* *manipulator* -refill -to-limit 32 -per-item` - This is a simple command to refill your inventory with supplies from a central chest but only with things that you are currently using (aka. things in your inventory). Useful when building.

`hopper *manipulator* *chest* -from-limit-max 10 -per-item -to-limit-min 1 -per-item` - This is a command to automatically clean your inventory of random mob drops. What a "mob drop" is is defined by the `-to-limit-min`; A mob drop is any item that there's already some of in the mob drops chest. The `-from-limit-max` ensures it only hoppers away small amounts of loot that you just picked up and not large amounts that you took out from a chest and are attempting to transport or craft with.

`hopper *chest* *shulker* -to-limit-min 1 -per-slot-number -to-limit 16 -per-slot` - This is a command to ease filling shulker boxes with items in a particular arrangement. As long as one correctly filled box is connected, the rest of the boxes will only receive items in the correct slots, although not necessarily in the same amounts as in the example box. The `-to-limit` restricts each slot to only having a maximum of 16 items for aesthetic purposes.
