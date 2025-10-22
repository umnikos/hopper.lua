local function argcount(f)
  local argcount = debug.getinfo(f, "u").nparams
  if not argcount then
    error("BUG DETECTED: argcount() returned nil")
  end
  return argcount
end

local function is_valid_name(s)
  return not string.find(s, "[^a-zA-Z_]")
end

-- a lookup table of what to do for each flag
-- each entry contains a .call function and an .argcount number
-- if an entry instead contains a string it's an alias
local primary_flags = {
  ["-once"] = function(...)
    local arg = ({...})[1]
    if type(arg) == "boolean" then
      PROVISIONS.options.once = arg
    else
      PROVISIONS.options.once = true
    end
  end,
  ["-forever"] = function(...)
    local arg = ({...})[1]
    if type(arg) == "boolean" then
      PROVISIONS.options.once = not arg
    else
      PROVISIONS.options.once = false
    end
  end,
  ["-quiet"] = function() PROVISIONS.options.quiet = true end,
  ["-verbose"] = function()
    if PROVISIONS.is_lua then
      error("cannot use -verbose through the lua api")
    end
    PROVISIONS.options.quiet = false
  end,
  ["-debug"] = function() PROVISIONS.options.debug = true end,
  ["-energy"] = function() PROVISIONS.options.energy = true end,
  ["-not"] = "-negate",
  ["-negated"] = "-negate",
  ["-negate"] = function() PROVISIONS.options.negate = true end,
  ["-nbt"] = function(nbt)
    -- this should only deny UPW
    -- FIXME: implement nbt hashes for ME bridge and then change this and other relevant flags
    PROVISIONS.setDenySlotless()
    PROVISIONS.positional()
    PROVISIONS.filters[#PROVISIONS.filters].nbt = nbt
  end,
  ["-from-slot"] = function(slot)
    PROVISIONS.setDenySlotless()
    PROVISIONS.options.from_slot = PROVISIONS.options.from_slot or {}
    if type(slot) == "table" then
      for _,s in ipairs(slot) do
        table.insert(PROVISIONS.options.from_slot, s)
      end
    else
      table.insert(PROVISIONS.options.from_slot, tonumber(slot))
    end
  end,
  ["-from-slot-range"] = function(s, e)
    PROVISIONS.setDenySlotless()
    PROVISIONS.positional()
    PROVISIONS.options.from_slot = PROVISIONS.options.from_slot or {}
    table.insert(PROVISIONS.options.from_slot, {tonumber(s), tonumber(e)})
  end,
  ["-to-slot"] = function(slot)
    PROVISIONS.setDenySlotless()
    PROVISIONS.options.to_slot = PROVISIONS.options.to_slot or {}
    if type(slot) == "table" then
      for _,s in ipairs(slot) do
        table.insert(PROVISIONS.options.to_slot, s)
      end
    else
      table.insert(PROVISIONS.options.to_slot, tonumber(slot))
    end
  end,
  ["-to-slot-range"] = function(s, e)
    PROVISIONS.setDenySlotless()
    PROVISIONS.positional()
    PROVISIONS.options.to_slot = PROVISIONS.options.to_slot or {}
    table.insert(PROVISIONS.options.to_slot, {tonumber(s), tonumber(e)})
  end,
  ["-preserve-order"] = "-preserve-slots",
  ["-preserve-slots"] = function()
    PROVISIONS.setDenySlotless()
    PROVISIONS.options.preserve_slots = true
  end,
  ["-batch-min"] = "-min-batch",
  ["-min-batch"] = function(arg)
    PROVISIONS.options.min_batch = tonumber(arg)
  end,
  ["-batch-max"] = "-min-batch",
  ["-max-batch"] = function(arg)
    table.insert(PROVISIONS.options.limits, {
      type = "transfer",
      limit = tonumber(arg),
      per_slot = true,
      per_chest = true,
    })
  end,
  ["-batch-multiple"] = function(arg)
    PROVISIONS.options.batch_multiple = tonumber(arg)
  end,
  ["-from-limit"] = "-from-limit-min",
  ["-from-limit-min"] = function(arg)
    PROVISIONS.positional()
    table.insert(PROVISIONS.options.limits, {
      type = "from",
      dir = "min",
      limit = tonumber(arg),
    })
  end,
  ["-from-limit-max"] = function(arg)
    PROVISIONS.positional()
    table.insert(PROVISIONS.options.limits, {
      type = "from",
      dir = "max",
      limit = tonumber(arg),
    })
  end,
  ["-to-limit-min"] = function(arg)
    PROVISIONS.positional()
    table.insert(PROVISIONS.options.limits, {
      type = "to",
      dir = "min",
      limit = tonumber(arg),
    })
  end,
  ["-to-limit"] = "-to-limit-max",
  ["-to-limit-max"] = function(arg)
    PROVISIONS.positional()
    table.insert(PROVISIONS.options.limits, {
      type = "to",
      dir = "max",
      limit = tonumber(arg),
    })
  end,
  ["-refill"] = function()
    -- -to-limit-min 1 -per-chest -per-item
    PROVISIONS.positional()
    table.insert(PROVISIONS.options.limits, {
      type = "to",
      dir = "min",
      limit = 1,
      per_name = true,
      per_chest = true,
    })
  end,
  ["-transfer-limit"] = function(arg)
    PROVISIONS.positional()
    table.insert(PROVISIONS.options.limits, {
      type = "transfer",
      limit = tonumber(arg),
    })
  end,
  ["-per-slot"] = function()
    PROVISIONS.setDenySlotless()
    PROVISIONS.positional()
    PROVISIONS.options.limits[#PROVISIONS.options.limits].per_slot = true
    PROVISIONS.options.limits[#PROVISIONS.options.limits].per_chest = true
  end,
  ["-per-chest"] = function()
    PROVISIONS.positional()
    PROVISIONS.options.limits[#PROVISIONS.options.limits].per_chest = true
  end,
  ["-per-slot-number"] = function()
    PROVISIONS.setDenySlotless()
    PROVISIONS.positional()
    PROVISIONS.options.limits[#PROVISIONS.options.limits].per_slot = true
  end,
  ["-per-item"] = function()
    PROVISIONS.positional()
    PROVISIONS.options.limits[#PROVISIONS.options.limits].per_name = true
  end,
  ["-per-nbt"] = function()
    PROVISIONS.setDenySlotless() -- FIXME
    PROVISIONS.positional()
    PROVISIONS.options.limits[#PROVISIONS.options.limits].per_name = true
    PROVISIONS.options.limits[#PROVISIONS.options.limits].per_nbt = true
  end,
  ["-count-all"] = function()
    PROVISIONS.positional()
    PROVISIONS.options.limits[#PROVISIONS.options.limits].count_all = true
  end,
  ["-alias"] = function(name, pattern)
    if not is_valid_name(name) then
      error("Invalid name for -alias: "..name)
    end
    register_alias({name = name, pattern = pattern})
  end,
  ["-storage"] = function(name, pattern)
    if not is_valid_name(name) then
      error("Invalid name for -storage: "..name)
    end
    table.insert(dont_rescan_patterns, pattern)
    register_alias({name = name, pattern = pattern})
  end,
  ["-sleep"] = function(secs)
    PROVISIONS.options.sleep = tonumber(secs)
  end,
  ["-scan-threads"] = function(secs)
    PROVISIONS.options.scan_threads = tonumber(secs)
  end,
  ["-ender"] = function()
    PROVISIONS.options.ender = true
  end,
  -- purely for the table api
  -- (although they'll also be usable through the normal api)
  ["-sources"] = "-from",
  ["-from"] = function(s)
    PROVISIONS.from = s
  end,
  ["-dests"] = "-to",
  ["-destinations"] = "-to",
  ["-to"] = function(s)
    PROVISIONS.to = s
  end,
  ["-items"] = "-filters",
  ["-filter"] = "-filters",
  ["-filters"] = function(l)
    if type(l) ~= "table" or l[1] == nil then
      l = {l}
    end
    for _,f in ipairs(l) do
      if type(f) == "table" then
        table.insert(PROVISIONS.filters, f)
      elseif type(f) == "function" then
        -- function filter (infinite possibilities)
        table.insert(PROVISIONS.filters, f)
      else
        if f:sub(1, 1) == "$" then
          -- tag
          table.insert(PROVISIONS.filters, {tag = f:sub(2)})
        else
          -- item filter
          table.insert(PROVISIONS.filters, {name = f})
        end
      end
    end
  end,
  ["-limits"] = function(l)
    if l[1] == nil then
      -- singular limit
      l = {l}
    end
    for _,limit in ipairs(l) do
      local default_dir
      if limit.type == "from" then
        default_dir = "min"
      elseif limit.type == "to" then
        default_dir = "max"
      elseif limit.type == "transfer" then
        -- no dir for it
      else
        error("unknown limit type: "..limit.type)
      end

      table.insert(PROVISIONS.options.limits, {
        type = limit.type,
        dir = limit.dir or default_dir,
        limit = limit.limit,
        per_slot = limit.per_slot_number or limit.per_slot,
        per_chest = limit.per_chest or limit.per_slot,
        per_name = limit.per_item or limit.per_nbt,
        per_nbt = limit.per_nbt,
        count_all = limit.count_all,
      })
    end
  end,
}

-- the flags table that'll actually be used
-- when indexing aliases it instead returns the unaliased entry it's pointing to
local flags = {}
setmetatable(flags, {
  __index = function(t, k)
    local f = primary_flags[k]
    if not f then return nil end
    if type(f) == "string" then
      return t[f]
    else
      return f
    end
  end,
})

local function hopper_parser_singular(args, is_lua)
  return provide({
    from = undefined,
    to = undefined,
    is_lua = is_lua,
    options = {
      quiet = is_lua,
      once = is_lua,
      sleep = 1,
      scan_threads = 8,
      limits = {},
      storages = {},
      denySlotless = nil, -- UPW and MEBridge cannot work with some of the flags here
    },
    filters = {},
    setDenySlotless = undefined,
    positional = undefined,
  }, function()
    local i = 1
    local current_flag_name
    PROVISIONS.setDenySlotless = function()
      PROVISIONS.options.denySlotless = PROVISIONS.options.denySlotless or current_flag_name
    end
    PROVISIONS.positional = function() end
    if type(args) == "table" then
      -- table api
      -- everything is treated as a flag
      PROVISIONS.positional = function()
        error("the flag '"..current_flag_name.."' cannot be used through the table API, use an alternative instead")
      end
      for flag_name,params in pairs(args) do
        current_flag_name = flag_name
        if type(params) ~= "table" or table[1] == nil then
          params = {params}
        end
        local flag = flags["-"..(flag_name:gsub("_", "-"))]
        if not flag then
          error("UNKNOWN PARAMETER KEY: "..flag_name)
        end
        flag(table.unpack(params))
      end
    else
      -- string api
      -- get rid of comments
      local args_string = args:gsub("%-%-.-\n", "\n"):gsub("%-%-.-$", "")
      -- tokenize
      local args = {}
      for arg in args_string:gmatch("%S+") do
        table.insert(args, arg)
      end
      -- run through each token and parse
      while i <= #args do
        if glob("-*", args[i]) then
          -- a flag
          current_flag_name = args[i]
          local flag = flags[args[i]:gsub("_", "-")]
          if not flag then
            error("UNKNOWN FLAG: "..args[i])
          end
          local params = {}
          argn = argcount(flag)
          for j = 1,argn do
            i = i+1
            table.insert(params, args[i])
          end
          flag(table.unpack(params))
        else
          -- positional argument
          if not PROVISIONS.from then
            PROVISIONS.from = args[i]
          elseif not PROVISIONS.to then
            PROVISIONS.to = args[i]
          else
            -- either an item filter or a tags filter
            if args[i]:sub(1, 1) == "$" then
              -- tag
              table.insert(PROVISIONS.filters, {tag = args[i]:sub(2)})
            else
              -- item filter
              table.insert(PROVISIONS.filters, {name = args[i]})
            end
          end
        end
        i = i+1
      end
    end
    return PROVISIONS.from, PROVISIONS.to, PROVISIONS.filters, PROVISIONS.options
  end)
end

-- returns: {from,to,filters,options}[], options
function parser(args, is_lua)
  if type(args) == "table" then
    -- table api!
    if args[1] == nil then
      -- singular command and not a list
      -- turn it into a list of one command
      args = {args}
    end
  elseif type(args) == "string" then
    -- normal api
    -- split on `/`s then pass it through hopper_parser_singular as if it's the table api
    local args_string = args.." / "
    args = {}
    for s in args_string:gmatch("(.-)%s/%s") do
      table.insert(args, s)
    end
  end

  local global_options
  local commands = {}
  for _,arg in ipairs(args) do
    local from, to, filters, options = hopper_parser_singular(arg, is_lua)
    if from then
      table.insert(commands, {from = from, to = to, filters = filters, options = options})
    end
    if not global_options then
      global_options = options
    end
  end
  return commands, global_options
end
