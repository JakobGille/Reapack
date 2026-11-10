-- @description Create Tracks Under Parent Folder (Per-Channel Routing)
-- @author Jakob Gille & Cline AI
-- @version 1.3
-- @about
--   Creates a new parent folder track at the end of the track list with N
--   child tracks underneath it (N is entered by the user). Every child
--   track uses its native parent send to reach its own parent channel:
--     Child 1: channel 1 -> parent channel 1
--     Child 2: channel 1 -> parent channel 2
--     Child 3: channel 1 -> parent channel 3
--     ...
--   (parent send channel offset = i - 1, parent send channel count = 1,
--   i.e. mono channels, not stereo groups)
--   The parent track gets the user-selected channel count and forwards all
--   of its channels 1..N to the master channels 1..N through its own main
--   send (C_MAINSEND_NCH = N). No explicit sends are created on the normal
--   path. On REAPER versions that do not accept these main-send settings,
--   the script falls back to explicit mono sends (a note about this is
--   printed to the REAPER console only when DEBUG is enabled at the top
--   of the script).
--
--   Notes:
--   - REAPER limits every track to 64 channels, so N must be between 1 and 64.
--   - REAPER tracks use even channel counts, so N is rounded up to the next
--     even number for the parent and the master.
--   - The child tracks are plain stereo (2-channel) tracks, independent of
--     the project default track channel count.
--   - Everything is wrapped in a single undo block, so one Ctrl+Z removes
--     the complete structure again.
-- @changelog
--   + 1.3: Console output is now disabled by default. Set DEBUG at the top
--     of the script to true to print status and fallback notes to the
--     REAPER console.
--   + 1.2: Children are plain stereo (2-channel) tracks, independent of the
--     project default track channel count.

--------------------------------------------------------------------------------
-- USER CONFIGURATION
--------------------------------------------------------------------------------

local DEFAULT_TRACK_COUNT = 4       -- Prefill of the "Number of tracks" input field
local DEFAULT_BASE_NAME   = "Track" -- Default base name if the field is left empty
local MAX_TRACKS          = 64      -- REAPER limit: 64 channels per track

-- Debug switch: print status and fallback notes to the REAPER console.
-- Disabled by default so that running the script does not open the
-- console window.
local DEBUG = false

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

-- Show an error message box
local function fail(msg)
  reaper.ShowMessageBox(msg, "Create Tracks Under Parent Folder", 0)
end

-- Print a message to the REAPER console, but only when DEBUG is enabled.
-- Disabled by default so that running the script does not open the console.
local function log(msg)
  if DEBUG then
    reaper.ShowConsoleMsg(msg)
  end
end

-- Round up to the next even number (REAPER tracks use even channel counts)
local function round_up_even(n)
  if n % 2 == 0 then
    return n
  end
  return n + 1
end

-- Ask the user for the number of tracks and an optional base name.
-- Returns num_tracks (integer) and base_name (string), or nil on cancel
-- or invalid input.
local function ask_user()
  local retval, input = reaper.GetUserInputs(
    "Create Tracks Under Parent Folder",
    2,
    "Number of tracks:,Base name (optional):",
    DEFAULT_TRACK_COUNT .. "," .. DEFAULT_BASE_NAME
  )
  if not retval then
    return nil -- user cancelled, nothing changed
  end

  -- Field 1: whole number between 1 and MAX_TRACKS
  local count_str, base_name = input:match("^([^,]*),?(.*)$")
  local num_tracks = tonumber(count_str and count_str:match("^%s*(%d+)%s*$"))
  if not num_tracks or num_tracks < 1 or num_tracks > MAX_TRACKS then
    fail("Please enter a whole number between 1 and " .. MAX_TRACKS ..
         ".\n\nREAPER supports up to 64 channels per track.")
    return nil
  end

  -- Field 2: base name (optional). If the user types extra commas, they end
  -- up in the name - the greedy match above handles that gracefully.
  base_name = base_name:match("^%s*(.-)%s*$")
  if base_name == "" then
    base_name = DEFAULT_BASE_NAME
  end

  return num_tracks, base_name
end

--------------------------------------------------------------------------------
-- MAIN
--------------------------------------------------------------------------------

local function main(num_tracks, base_name)
  local needed_chans = round_up_even(num_tracks)

  -- Extend the master track so it can receive all parent channels
  -- (only ever extend, never shrink an existing channel count)
  local master = reaper.GetMasterTrack(0)
  local master_chans = reaper.GetMediaTrackInfo_Value(master, "I_NCHAN")
  if master_chans < needed_chans then
    reaper.SetMediaTrackInfo_Value(master, "I_NCHAN", needed_chans)
  end

  -- Create the parent folder track at the end of the track list
  local insert_idx = reaper.CountTracks(0) -- 0-based index: one past the last track
  reaper.InsertTrackAtIndex(insert_idx, false)
  local parent = reaper.GetTrack(0, insert_idx)
  reaper.GetSetMediaTrackInfo_String(parent, "P_NAME", base_name .. " Folder", true)

  -- The parent needs one channel per child. All of its channels are
  -- forwarded to the master through its own native main send:
  -- parent channels 1..N -> master channels 1..N.
  reaper.SetMediaTrackInfo_Value(parent, "I_NCHAN", needed_chans)
  reaper.SetMediaTrackInfo_Value(parent, "C_MAINSEND_OFFS", 0)
  reaper.SetMediaTrackInfo_Value(parent, "C_MAINSEND_NCH", num_tracks)
  local parent_fwd_native = reaper.GetMediaTrackInfo_Value(parent, "C_MAINSEND_NCH") == num_tracks
  if not parent_fwd_native then
    -- Fallback for REAPER versions that clamp the main send channel count:
    -- disable the main send and use explicit mono sends instead.
    reaper.SetMediaTrackInfo_Value(parent, "B_MAINSEND", 0)
    for i = 1, num_tracks do
      local send_idx = reaper.CreateTrackSend(parent, master)
      if not send_idx or send_idx < 0 then
        fail("Could not create the send from the parent track to the master " ..
             "track (channel " .. i .. "). Press Ctrl+Z to remove everything.")
        return false
      end
      reaper.SetTrackSendInfo_Value(parent, 0, send_idx, "I_SRCCHAN", i - 1)
      reaper.SetTrackSendInfo_Value(parent, 0, send_idx, "I_DSTCHAN", i - 1)
    end
  end

  -- Create the child tracks directly under the parent and route each one
  local children = {}
  local child_fallbacks = 0
  for i = 1, num_tracks do
    reaper.InsertTrackAtIndex(insert_idx + i, false)
    local child = reaper.GetTrack(0, insert_idx + i)
    reaper.GetSetMediaTrackInfo_String(child, "P_NAME", base_name .. " " .. i, true)

    -- Children are plain stereo tracks (2 channels), independent of the
    -- project default track channel count.
    reaper.SetMediaTrackInfo_Value(child, "I_NCHAN", 2)

    -- Route child channel 1 (mono) to parent channel i via the native
    -- parent send: the main send takes the first C_MAINSEND_NCH channels of
    -- the child and lands them on parent channels starting at
    -- C_MAINSEND_OFFS + 1. B_MAINSEND stays enabled (default).
    reaper.SetMediaTrackInfo_Value(child, "C_MAINSEND_OFFS", i - 1)
    reaper.SetMediaTrackInfo_Value(child, "C_MAINSEND_NCH", 1)

    if reaper.GetMediaTrackInfo_Value(child, "C_MAINSEND_NCH") ~= 1 then
      -- This REAPER version does not accept a mono parent send:
      -- fall back to an explicit mono send instead.
      reaper.SetMediaTrackInfo_Value(child, "B_MAINSEND", 0)
      local send_idx = reaper.CreateTrackSend(child, parent)
      if not send_idx or send_idx < 0 then
        fail("Could not create the send from '" .. base_name .. " " .. i ..
             "' to the parent track.")
        return false
      end
      -- I_SRCCHAN: 0 = mono source channel 1; I_DSTCHAN: 0-based parent channel
      reaper.SetTrackSendInfo_Value(child, 0, send_idx, "I_SRCCHAN", 0)
      reaper.SetTrackSendInfo_Value(child,  0, send_idx, "I_DSTCHAN", i - 1)
      child_fallbacks = child_fallbacks + 1
    end

    children[#children + 1] = child
  end

  -- Close the folder: +1 on the parent opens it, -1 on the last child closes it
  reaper.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", 1)
  reaper.SetMediaTrackInfo_Value(children[num_tracks], "I_FOLDERDEPTH", -1)

  -- NOTE: parent-to-master forwarding happens through the parent's native
  -- main send (C_MAINSEND_NCH set above); no explicit sends are created on
  -- the normal path.

  -- Select the new child tracks for immediate further editing
  for i = 0, reaper.CountTracks(0) - 1 do
    reaper.SetTrackSelected(reaper.GetTrack(0, i), false)
  end
  for _, child in ipairs(children) do
    reaper.SetTrackSelected(child, true)
  end

  if child_fallbacks > 0 then
    log(
        "Note: this REAPER version did not accept mono parent sends " ..
        "(C_MAINSEND_NCH = 1), so explicit mono sends were created for " ..
        child_fallbacks .. " child track(s) instead.\n")
  end
  if not parent_fwd_native then
    log(
        "Note: parent-to-master forwarding uses explicit sends because " ..
        "this REAPER version did not accept a multichannel main send.\n")
  end

  return true
end

--------------------------------------------------------------------------------
-- ENTRY POINT
--------------------------------------------------------------------------------

local num_tracks, base_name = ask_user()
if num_tracks then
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  local ok = main(num_tracks, base_name)

  reaper.Undo_EndBlock("Create " .. num_tracks .. " track(s) under parent folder (channel routing)", -1)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  if ok then
    log(string.format(
      "Create Tracks Under Parent Folder: created %d track(s) under '%s Folder'.\n" ..
      "Parent and master channels: %d\n" ..
      "Routing (native parent sends): child channel 1 -> parent channel i, " ..
              "parent channels 1..N -> master channels 1..N\n",
      num_tracks, base_name, round_up_even(num_tracks)))
  end
end

