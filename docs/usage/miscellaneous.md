# Various other options

- `-once` - run the script only once instead of in a loop (undo with `-forever`)
- `-quiet` - don't print anything to the terminal (undo with `-verbose`)
- `-negate` - instead of transferring if any filter matches, transfer if no filters match
- `-nbt [nbt string]` - change the filter just before this flag to match only items with the given nbt
- `-sleep [num]` - set the delay in seconds between each iteration (default is 1)
- `-debug` - show more information when running and update the information more frequently
- `-scan-threads [num]` - set the number of threads to be used during scanning. default is 8
