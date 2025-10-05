local cursor_x, cursor_y = 1, 1
local function save_cursor()
  cursor_x, cursor_y = term.getCursorPos()
  local sizex, sizey = term.getSize()
  local margin = 2 -- space to leave at the bottom of the screen
  cursor_y = math.min(cursor_y, sizey-margin)
end
local function clear_below()
  local _, y = term.getCursorPos()
  local _, sizey = term.getSize()
  while y < sizey do
    y = y+1
    term.setCursorPos(1, y)
    term.clearLine()
  end
end
local function go_back()
  term.setCursorPos(cursor_x, cursor_y)
end

-- mbs messes with the term api
-- so for correct output we have to tell it when we start and stop messing with it
local term_current = term.current()
local function mbs_start()
  (term_current.beginPrivateMode or function() end)()
end
local function mbs_end()
  (term_current.endPrivateMode or function() end)()
end

local function format_time(time)
  if time < 60*60 then -- less than an hour => format as minutes and seconds
    local seconds = math.floor(time)
    local minutes = math.floor(seconds/60)
    seconds = seconds-60*minutes
    return minutes.."m "..seconds.."s"
  else -- format as hours and minutes
    local minutes = math.floor(time/60)
    local hours = math.floor(minutes/60)
    minutes = minutes-60*hours
    return hours.."h "..minutes.."m"
  end
end



function display_exit(args_string)
  local start_time = PROVISIONS.start_time
  if PROVISIONS.global_options.quiet then
    return
  end
  local total_transferred = PROVISIONS.report_transfer(0)
  local elapsed_time = 0
  if start_time then
    elapsed_time = os.clock()-start_time
  end
  local ips = (total_transferred/elapsed_time)
  if ips ~= ips then
    ips = 0
  end
  go_back()
  if PROVISIONS.global_options.debug then
    print("           ")
  end
  mbs_end()
  print("total uptime: "..format_time(elapsed_time))
  print("transferred total: "..format_number(total_transferred).." ("..format_number(ips, 2).." i/s)    ")
end

-- FIXME: MAKE BETTER ERROR PROPAGATION THAN SETTING A GLOBAL
-- local latest_error = nil

function display_loop(args_string)
  if PROVISIONS.global_options.quiet then
    halt()
  end
  local start_time = PROVISIONS.start_time
  mbs_start()
  term.clear()
  go_back()
  print("hopper.lua "..version)
  args_string = args_string:gsub("%s+/%s+", "\n/ ")
  print("$ hopper "..args_string)
  print("")
  save_cursor()

  local time_to_wake = start_time
  while true do
    local total_transferred = PROVISIONS.report_transfer(0)
    local elapsed_time = os.clock()-start_time
    local ips = (total_transferred/elapsed_time)
    if ips ~= ips then
      ips = 0
    end
    go_back()
    if PROVISIONS.global_options.debug then
      print((PROVISIONS.hoppering_stage or "nilstate").."        ")
    end
    print("uptime: "..format_time(elapsed_time).."    ")
    if latest_error then
      term.clearLine()
      print("")
      print(latest_error)
    else
      term.write("transferred so far: "..format_number(total_transferred).." ("..format_number(ips, 2).." i/s)    ")
      clear_below()
    end
    if PROVISIONS.global_options.debug then
      sleep(0)
    else
      local current_time = os.clock()
      time_to_wake = time_to_wake+1
      sleep(time_to_wake-current_time)
    end
  end
end
