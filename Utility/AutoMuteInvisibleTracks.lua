-- @description Auto Mute Invisible Tracks (CPU saver)
-- @author Jakob Gille
-- @version 1.0
-- @about
--   Saves CPU resources in two ways: tracks that are currently scrolled out
--   of the visible arrangement area are automatically muted (rule A), and
--   muted tracks always get their FX chain switched off (rule B - the real
--   CPU lever, because REAPER keeps processing the FX of muted tracks).
--   When a track comes back into view, its original mute state is restored
--   after a short debounce. Tracks hidden via the Track Manager or in
--   collapsed folders are not touched; record-armed and frozen tracks are
--   always left alone.
--   Start: run the script once - it runs in the background (defer loop).
--   Stop: run it again - everything is restored. Changes made by the script
--   appear in the next undo point.
--   IMPORTANT: stop the script before rendering/exporting (invisible tracks
--   would be muted in the render). Re-enabling FX chains can cause short
--   PDC/latency jumps.
--   REQUIRES js_ReaScriptAPI (determines the visible area; without it, rule
--   A is suspended and only rule B stays active).
-- @changelog
--   + 1.0: Initial release

----------------------------------------------------------------------
-- CONFIGURATION
----------------------------------------------------------------------
local CFG = {
  TICK_HZ                   = 10,    -- checks per second (background loop)
  MIN_OVERLAP_PX            = 1,     -- at least this many visible pixels => "visible"
  HYSTERESIS_S              = 0.3,   -- debounce time before restoring (seconds)
  ENFORCE_DURING_PLAYBACK   = false, -- apply the rules during playback as well?
  APPLY_MUTE_RULE_TO_HIDDEN = true,  -- apply rule B to hidden tracks too (I_TCPH == 0)?
  SPARE_SELECTED            = true,  -- exempt selected tracks from rule A?
  INCLUDE_MASTER            = false, -- include the master track in rule B?
  SHOW_DEBUG                = false, -- debug output to the ReaScript console
}

local EXT_SECTION    = "AutoMuteInvisibleTracks"
local P_EXT_KEY      = "P_EXT:AutoMuteInvisibleTracks"
local TRACKVIEW_NAME = "trackview" -- internal window of the arrange view (js_ReaScriptAPI)

----------------------------------------------------------------------
-- Track state (persisted in the project via P_EXT so that nothing stays
-- stuck in a wrong state after a crash/restart)
--
--   sm = script muted because of invisibility          (0/1)
--   sf = script switched the FX chain off              (0/1)
--   om = original mute state of the user               (0/1)
--   of = original FX state of the user                 (0/1)
--   vs = timestamp: since when visible again (0 = never)
----------------------------------------------------------------------
local function read_state(tr)
  local _, val = reaper.GetSetMediaTrackInfo_String(tr, P_EXT_KEY, "", false)
  if not val or val == "" then return nil end
  local t = {}
  for tok in val:gmatch("%S+") do t[#t + 1] = tonumber(tok) end
  if #t < 5 or not t[1] or not t[2] or not t[3] or not t[4] or not t[5] then return nil end
  if t[1] == 0 and t[2] == 0 then return nil end -- no active interventions
  return { sm = t[1], sf = t[2], om = t[3], of = t[4], vs = t[5] }
end

local function write_state(tr, st)
  reaper.GetSetMediaTrackInfo_String(tr, P_EXT_KEY,
    string.format("%d %d %d %d %.3f", st.sm, st.sf, st.om, st.of, st.vs), true)
end

local function clear_state(tr)
  reaper.GetSetMediaTrackInfo_String(tr, P_EXT_KEY, "", true)
end

local function make_state(mute, fxen)
  return {
    sm = 0, sf = 0,
    om = (mute >= 0.5) and 1 or 0,
    of = (fxen  >= 0.5) and 1 or 0,
    vs = 0,
  }
end

----------------------------------------------------------------------
-- Geometry / visibility
----------------------------------------------------------------------
local function get_track_geo(tr)
  return
    reaper.GetMediaTrackInfo_Value(tr, "I_TCPY"),  -- Y position in the arrange view (pixels)
    reaper.GetMediaTrackInfo_Value(tr, "I_TCPH")   -- height (0 = hidden)
end

local function overlaps_viewport(y, h, bottom)
  local overlap = math.min(y + h, bottom) - math.max(y, 0)
  return overlap >= CFG.MIN_OVERLAP_PX
end

-- Height of the visible track area via the trackview window (js_ReaScriptAPI)
local function get_viewport_bottom_js()
  if not reaper.JS_Window_Find or not reaper.JS_Window_GetClientRect then return nil end
  local hwnd = reaper.JS_Window_Find(TRACKVIEW_NAME, true)
  if not hwnd then return nil end
  local left, top, right, bottom = reaper.JS_Window_GetClientRect(hwnd)
  if not (left and top and right and bottom) then return nil end
  local h = bottom - top
  if h and h > 0 then return h end
  return nil
end

-- Detect frozen tracks (I_FROZEN, REAPER 6.29+; always 0 otherwise)
local function is_frozen(tr)
  return reaper.GetMediaTrackInfo_Value(tr, "I_FROZEN") ~= 0
end

----------------------------------------------------------------------
-- Debug
----------------------------------------------------------------------
local function dbg(fmt, ...)
  if CFG.SHOW_DEBUG then reaper.ShowConsoleMsg(string.format(fmt, ...)) end
end


----------------------------------------------------------------------
-- Per-track intervention (rule A + rule B)
----------------------------------------------------------------------
local function process_track(tr, y, h, bottom, is_master, now)
  local mute   = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE")
  local fxen   = reaper.GetMediaTrackInfo_Value(tr, "I_FXEN")
  local armed  = reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") > 0
  local sel    = reaper.GetMediaTrackInfo_Value(tr, "I_SELECTED") > 0
  local hidden = (h <= 0)
  local st = read_state(tr)

  -- Record-armed or frozen tracks: the script backs off completely
  -- and restores any changes it made before
  if armed or is_frozen(tr) then
    if st and (st.sm == 1 or st.sf == 1) then
      if st.sm == 1 then
        reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", st.om)
      end
      if st.sf == 1 then
        reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", st.of)
      end
      clear_state(tr)
    end
    return
  end

  -- Rule A: mute follows visibility (scroll area only!)
  -- Hidden tracks (I_TCPH == 0) and the master stay untouched.
  local visible = nil
  if bottom and not hidden and not is_master then
    visible = overlaps_viewport(y, h, bottom)
    if CFG.SPARE_SELECTED and sel then visible = true end
  end
  if visible == false then
    -- invisible -> save the state and force mute
    if not st then
      st = make_state(mute, fxen)
      write_state(tr, st)
    end
    if mute < 0.5 then
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
      mute = 1
      dbg("  -> track invisible, muted (y=%.0f h=%.0f)\n", y, h)
    end
    if st.sm == 0 then
      st.sm = 1
      st.vs = 0
      write_state(tr, st)
    end
  elseif visible and st and st.sm == 1 then
    -- visible again -> restore the original mute after the debounce time
    if st.vs == 0 then
      st.vs = now
      write_state(tr, st)
    elseif now - st.vs >= CFG.HYSTERESIS_S then
      local orig = (st.om >= 0.5) and 1 or 0
      if (mute >= 0.5 and 1 or 0) ~= orig then
        reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", orig)
        mute = orig
        dbg("  -> track visible again, mute restored\n")
      end
      st.sm = 0
      write_state(tr, st)
    end
  end

  -- Rule B: the FX chain follows mute (always, regardless of visibility)
  if reaper.TrackFX_GetCount(tr) > 0
     and ((h > 0) or CFG.APPLY_MUTE_RULE_TO_HIDDEN) then
    if mute >= 0.5 then
      if fxen >= 0.5 then
        if not st then
          st = make_state(mute, fxen)
        end
        if st.sf == 0 then
          st.of = 1  -- FX was on, remember the original state
          st.sf = 1
          write_state(tr, st)
          reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 0)
        end
      end
    elseif st and st.sf == 1 and st.sm == 0 then
      -- unmuted -> restore the original FX state
      if (fxen >= 0.5 and 1 or 0) ~= st.of then
        reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", st.of)
      end
      st.sf = 0
      write_state(tr, st)
    end
  end

  -- Cleanup: no more active interventions -> clear the flag
  if st and st.sm == 0 and st.sf == 0 then
    clear_state(tr)
    st = nil
  end
end

----------------------------------------------------------------------
-- Determine the bottom edge of the visible track area (js_ReaScriptAPI)
--
-- IMPORTANT: I_TCPY of regular tracks is viewport-relative, therefore:
-- bottom edge = height of the trackview window.
--
-- The master track is USELESS here as a reference: in the TCP layout it
-- is placed after the last track and reports its content-flow position
-- (the sum of all track heights), NOT the viewport bottom edge. A
-- "master oracle" (master TCPY as the bottom edge) therefore caused
-- tracks scrolled out at the bottom to never be detected as invisible
-- (overlap = h >= 1).
----------------------------------------------------------------------
local function get_viewport_bottom(proj, sum_h)
  local js = get_viewport_bottom_js()
  if js then return js, "js" end
  return nil, "none"
end

----------------------------------------------------------------------
-- One pass over the active project
----------------------------------------------------------------------
local last_debug = 0
local warned_no_viewport = false

local function scan_project(now)
  local proj = reaper.EnumProjects(-1)
  if not proj then return end

  -- Optional: do not change anything during playback/recording
  if not CFG.ENFORCE_DURING_PLAYBACK then
    local ps = reaper.GetPlayStateEx and reaper.GetPlayStateEx(proj) or reaper.GetPlayState()
    if ps ~= 0 then return end
  end

  -- Read the geometry of all tracks once
  local n = reaper.CountTracks(proj)
  local tracks, sum_h, any_normal = {}, 0, false
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(proj, i)
    local y, h = get_track_geo(tr)
    tracks[#tracks + 1] = { tr = tr, y = y, h = h }
    sum_h = sum_h + h
    if h > 0 then any_normal = true end
  end

  -- Bottom edge of the visible area + watchdog against wrong assumptions
  local bottom, src = get_viewport_bottom(proj, sum_h)
  if bottom and any_normal then
    local vis = 0
    for _, t in ipairs(tracks) do
      if t.h > 0 and overlaps_viewport(t.y, t.h, bottom) then vis = vis + 1 end
    end
    if vis == 0 then
      -- Geometry assumption obviously wrong -> try another source,
      -- if necessary safety mode (no rule A interventions)
      local js = (src == "master") and get_viewport_bottom_js() or nil
      if js then
        bottom, src = js, "js fallback"
      else
        bottom = nil
      end
      dbg("[AMIT] watchdog: no visible track -> source: %s\n", src)
    end
  end

  if not bottom then
    if not warned_no_viewport then
      warned_no_viewport = true
      reaper.ShowConsoleMsg(
        "AutoMuteInvisibleTracks: visible area could not be determined - " ..
        "rule A suspended, rule B stays active.\n")
    end
  else
    warned_no_viewport = false
  end

  -- Master optional, only in rule B
  if CFG.INCLUDE_MASTER then
    local master = reaper.GetMasterTrack(proj)
    local my, mh = get_track_geo(master)
    process_track(master, my, mh, bottom, true, now)
  end

  for _, t in ipairs(tracks) do
    process_track(t.tr, t.y, t.h, bottom, false, now)
  end

  -- Debug line (at most once per second)
  if CFG.SHOW_DEBUG and (now - last_debug) >= 1 then
    last_debug = now
    local count_m, count_f = 0, 0
    for _, t in ipairs(tracks) do
      local s = read_state(t.tr)
      if s then
        if s.sm == 1 then count_m = count_m + 1 end
        if s.sf == 1 then count_f = count_f + 1 end
      end
    end
    dbg("[AMIT] bottom=%.0f (%s) | tracks=%d | total height=%.0f | muted by script=%d | FX off by script=%d\n",
      bottom or -1, src, n, sum_h, count_m, count_f)
  end
end

----------------------------------------------------------------------
-- Restore all changed tracks across ALL open projects
----------------------------------------------------------------------
local function restore_all()
  local restored = 0
  local idx = 0
  while true do
    local proj = reaper.EnumProjects(idx)
    if not proj then break end
    local n = reaper.CountTracks(proj)
    for i = 0, n - 1 do
      local tr = reaper.GetTrack(proj, i)
      local st = read_state(tr)
      if st then
        if st.sm == 1 then
          reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", st.om)
        end
        if st.sf == 1 then
          reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", st.of)
        end
        clear_state(tr)
        restored = restored + 1
      end
    end
    idx = idx + 1
  end
  return restored
end

----------------------------------------------------------------------
-- Toolbar toggle (best effort, only works as a toolbar action)
----------------------------------------------------------------------
local function get_section_cmd()
  local ok, vals = pcall(function() return { reaper.get_action_context() } end)
  if not ok or type(vals) ~= "table" then return nil, nil end
  -- Format A: retval, is_new, filename, section, mode, cmd, toggle
  if type(vals[4]) == "number" and type(vals[6]) == "number" then
    return vals[4], vals[6]
  end
  -- Format B: retval, filename, section, mode, cmd, toggle
  if type(vals[3]) == "number" and type(vals[5]) == "number" then
    return vals[3], vals[5]
  end
  return nil, nil
end

local function set_toolbar_toggle(on)
  if not reaper.get_action_context or not reaper.SetToggleCommandState then return end
  local section, cmd = get_section_cmd()
  if section and cmd and cmd > 0 then
    pcall(reaper.SetToggleCommandState, section, cmd, on and 1 or 0)
    pcall(reaper.RefreshToolbar2, section, cmd)
  end
end

----------------------------------------------------------------------
-- Main loop (defer), throttling via TICK_HZ
----------------------------------------------------------------------
local last_tick = 0

local function main_loop()
  if reaper.GetExtState(EXT_SECTION, "running") ~= "1" then
    return -- a second script run stopped it -> end the loop
  end
  local now = reaper.time_precise()
  if (now - last_tick) >= (1.0 / CFG.TICK_HZ) then
    last_tick = now
    scan_project(now)
  end
  reaper.defer(main_loop)
end

----------------------------------------------------------------------
-- Start / stop (toggle by running the script again)
----------------------------------------------------------------------
if reaper.GetExtState(EXT_SECTION, "running") == "1" then
  -- >>> STOP: reset all changes
  reaper.SetExtState(EXT_SECTION, "running", "0", false)
  local restored = restore_all()
  set_toolbar_toggle(false)
  reaper.ShowConsoleMsg(string.format(
    "AutoMuteInvisibleTracks: STOPPED - %d track(s) restored.\n", restored))
else
  -- >>> START: first clean up leftovers from a crashed session
  reaper.SetExtState(EXT_SECTION, "running", "1", false)
  local leftovers = restore_all()
  set_toolbar_toggle(true)
  if leftovers > 0 then
    reaper.ShowConsoleMsg(string.format(
      "AutoMuteInvisibleTracks: restored %d track(s) from a previous session.\n", leftovers))
  end
  reaper.ShowConsoleMsg(string.format(
    "AutoMuteInvisibleTracks: ACTIVE (%d Hz, debounce %.1f s) - run the script again to stop.\n",
    CFG.TICK_HZ, CFG.HYSTERESIS_S))
  reaper.defer(main_loop)
end


