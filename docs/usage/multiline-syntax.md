# Multiline syntax

Except in simple scenarios, a single hopper command rarely suffices. In earlier versions of hopper.lua the standard way to have multiple hopper commands run simultaneously was to have each one open in a separate tab with `bg`. This was not ideal, so the multiline command syntax was created.

In short, you can type out several hopper commands and separate them each with `/` to have multiple commands run on a single instance. This is a necessity if you want to use the `-storage` flag, but even if you don't it leads to a cleaner setup.

Example: `hopper left right / top bottom` - Moves items from the left chest to the right chest, and from the top chest to the bottom chest.

Options can either be per-command or global options. Only a few options are global, and they must be supplied to the first command in the list, otherwise they might be ignored. The list of global options is:
- `-sleep`
- `-once`
- `-quiet`
- `-storage`
- `-alias`

Good practices include using `[[` and `]]` to make a multiline string, putting each hopper command on its own line, and reserving the first command purely for global options.

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

Since v1.4.3 you can use `--` to add line comments as well.

Example: The above code but with some comments:
```lua
shell.openTab([[hopper -sleep 5 -- increase/decrease delay to taste
  -alias in *chest*_5938   -- input chest
  -alias out *chest*_5939  -- output chest
  -storage store *barrel*  -- array of barrels to keep items in
  / in store   -- store items in
  / store out  -- take items out
]])
```
