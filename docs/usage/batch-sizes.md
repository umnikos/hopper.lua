# Batch sizes

There's some weird setups where you need an item transfer operation to only occur when said operation has a specific size.
An example would be feeding a furnace exactly 8 items at a time to smelt, to ensure you never waste coal.
That's where the following flags come in handy:
- `-batch-multiple [number]` - Every transfer operation must involve an amount that's divisible by the number supplied.
- `-batch-min [number]`/`-min-batch [number]` - Every transfer operation must involve an amount that's at least as big as the supplied number.
- `-batch-max [number]`/`-max-batch [number]` - Every transfer operation must involve an amount that's at most the supplied number. It's currently an alias for `-transfer-limit [number] -per-slot` but that's not exactly identical so it might change in the future

Example: `hopper *chest* *furnace* -to-slot 1 -batch-multiple 8` - Feed furnace items to smelt in a way that ensures no coal is wasted
