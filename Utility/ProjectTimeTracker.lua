-- @description Project Time Tracker (Scalable UI, Edit Mode & Monthly Heatmap)
-- @author Jakob Gille & Mistral AI
-- @version 1.6
-- @about
--   Tracks active project working time based on audio playback, recording,
--   mouse movement (strictly restricted to REAPER foreground/windows), and
--   project state changes. Features a scalable UI, manual time editing,
--   per-plugin time tracking, a GitHub-style monthly activity heatmap with
--   day inspector, and persistent project storage (.rpp).

--------------------------------------------------------------------------------
-- CONSTANTS & CONFIGURATION
--------------------------------------------------------------------------------

local EXT_SECTION = "JG_PROJECT_TIME_TRACKER"
local WIN_SECTION = "JG_TIME_TRACKER_UI"

local BASE_W = 420
local BASE_H = 560

-- Hold time options in seconds
local HOLD_OPTIONS = { 2, 5, 15 }
local hold_idx = 2
local hold_time = HOLD_OPTIONS[hold_idx]

-- Periodic auto-save interval to project RAM state (in seconds)
local SAVE_INTERVAL = 5.0

-- Interval for marking the project dirty (triggers the "unsaved changes"
-- reminder). Tracked data is still written to the project RAM state every
-- SAVE_INTERVAL; only the dirty flag is throttled so save prompts stay rare.
local DIRTY_INTERVAL = 60.0

-- UI redraw throttle: while the mouse is outside the tracker window only the
-- ticking timer changes, so ~10 fps is plenty (saves CPU while idle)
local REDRAW_IDLE = 0.1

local MONTH_NAMES = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"
}
local WEEKDAY_LABELS = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }

-- GitHub-inspired green palette (Level 0 = empty, Level 1..4 = quartiles)
local HEATMAP_COLORS = {
    [0] = { 38, 42, 48 },    -- Empty day
    [1] = { 14, 68, 41 },    -- Low activity (> 0%)
    [2] = { 0, 109, 50 },    -- Medium-low (> 25%)
    [3] = { 38, 166, 65 },   -- Medium-high (> 50%)
    [4] = { 57, 211, 83 }    -- High activity (> 75%)
}

--------------------------------------------------------------------------------
-- STATE VARIABLES
--------------------------------------------------------------------------------

local total_time = 0.0
local arrange_time = 0.0
local playback_time = 0.0
local session_time = 0.0
local plugin_times = {}      -- Table: plugin_name -> seconds
local sorted_plugins = {}    -- Array for UI rendering
local daily_times = {}       -- Table: "YYYY-MM-DD" -> seconds

local is_paused = false
local is_active = false
local status_text = "IDLE"
local active_target_text = "None"

-- View & Heatmap navigation state
local active_tab = 1         -- 1 = Plugin List, 2 = Monthly Heatmap
local cur_date_table = os.date("*t")
local view_year = cur_date_table.year
local view_month = cur_date_table.month
local selected_date_str = os.date("%Y-%m-%d")

local last_time = reaper.time_precise()
local last_mx, last_my = reaper.GetMousePosition()
local last_proj_change = reaper.GetProjectStateChangeCount(0)
local last_activity_ts = 0.0
local last_save_ts = reaper.time_precise()
local last_dirty_ts = last_save_ts

-- Project identification state (prevents bleed when creating/loading in same tab)
local current_proj = nil
local current_proj_fn = nil
local current_proj_uuid = nil

local scroll_offset = 0
local max_scroll = 0
local last_mouse_cap = 0

-- Performance / housekeeping state
local plugins_dirty = false      -- sorted_plugins outdated (rebuild throttled)
local last_rebuild_ts = 0.0
local last_today_check = 0.0     -- cached date string refresh (10 s)
local last_uuid_check = 0.0      -- same-slot project reload check (0.5 s)
local last_draw_ts = 0.0         -- UI redraw throttle
local last_cap_check = 0         -- mouse_cap sampled every frame
local pending_click = false      -- click occurred between two throttled draws
local last_heartbeat_ts = 0.0    -- second-instance guard heartbeat

--------------------------------------------------------------------------------
-- HELPER FUNCTIONS: FORMATTING, CALENDAR & SERIALIZATION
--------------------------------------------------------------------------------

local function format_time(sec)
    sec = math.max(0, math.floor(sec or 0))
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function clean_fx_name(name)
    if not name or name == "" then return "Unknown Plugin" end
    return name
end

local function generate_uuid()
    return string.format("%d_%d_%d", os.time(), math.floor((reaper.time_precise() % 1) * 1000000), math.random(1000, 9999))
end

local function get_today_str()
    return os.date("%Y-%m-%d")
end

-- Cached "today" string (refreshed every 10 s in update_tracking to catch
-- midnight rollover without calling os.date on every active frame)
local today_str = get_today_str()

-- UTF-8 safe truncation by code points. Byte-based string.sub can cut a
-- multibyte character in half and render a broken glyph.
local function utf8_truncate(s, max_chars)
    local n = 0
    local out = {}
    for c in s:gmatch("[\0-\127\194-\244][\128-\191]*") do
        n = n + 1
        if n > max_chars then
            return table.concat(out), true
        end
        out[#out + 1] = c
    end
    return s, false
end

-- Returns number of days in a given month/year and Monday-based weekday of the 1st (1=Mo .. 7=Su)
local function get_month_layout(year, month)
    local first_day_ts = os.time({ year = year, month = month, day = 1, hour = 12 })
    local last_day_ts = os.time({ year = year, month = month + 1, day = 0, hour = 12 })
    local days_in_month = tonumber(os.date("%d", last_day_ts))

    local wday_sun = os.date("*t", first_day_ts).wday
    local first_wday_mon = ((wday_sun + 5) % 7) + 1

    return days_in_month, first_wday_mon
end

local function step_month(delta)
    view_month = view_month + delta
    if view_month > 12 then
        view_month = 1
        view_year = view_year + 1
    elseif view_month < 1 then
        view_month = 12
        view_year = view_year - 1
    end
end

local function rebuild_sorted_plugins()
    sorted_plugins = {}
    for name, sec in pairs(plugin_times) do
        if sec > 0 then
            table.insert(sorted_plugins, { name = name, time = sec })
        end
    end
    table.sort(sorted_plugins, function(a, b)
        return a.time > b.time
    end)
end

local function serialize_table(tbl)
    local lines = {}
    for k, sec in pairs(tbl) do
        if sec > 0.1 then
            local safe_k = tostring(k):gsub("[\r\n\t]", " ")
            table.insert(lines, string.format("%s\t%.2f", safe_k, sec))
        end
    end
    return table.concat(lines, "\n")
end

local function deserialize_table(str)
    local tbl = {}
    if not str or str == "" then return tbl end
    for line in str:gmatch("[^\r\n]+") do
        local k, sec_str = line:match("^(.-)\t([%d%.]+)$")
        if k and sec_str then
            tbl[k] = tonumber(sec_str) or 0.0
        end
    end
    return tbl
end

--------------------------------------------------------------------------------
-- PROJECT STATE STORAGE (.RPP PERSISTENCE)
--------------------------------------------------------------------------------

local function save_project_data(proj, mark_dirty)
    proj = proj or 0
    if proj ~= 0 and not reaper.ValidatePtr(proj, "ReaProject*") then return end

    if not current_proj_uuid or current_proj_uuid == "" then
        current_proj_uuid = generate_uuid()
    end

    reaper.SetProjExtState(proj, EXT_SECTION, "PROJ_UUID", current_proj_uuid)
    reaper.SetProjExtState(proj, EXT_SECTION, "TOTAL_TIME", string.format("%.2f", total_time))
    reaper.SetProjExtState(proj, EXT_SECTION, "ARRANGE_TIME", string.format("%.2f", arrange_time))
    reaper.SetProjExtState(proj, EXT_SECTION, "PLAYBACK_TIME", string.format("%.2f", playback_time))
    reaper.SetProjExtState(proj, EXT_SECTION, "PLUGINS", serialize_table(plugin_times))
    reaper.SetProjExtState(proj, EXT_SECTION, "DAILY_LOG", serialize_table(daily_times))

    if mark_dirty then
        reaper.MarkProjectDirty(proj)
    end
end

local function load_project_data(proj)
    proj = proj or 0
    local _, uuid_str = reaper.GetProjExtState(proj, EXT_SECTION, "PROJ_UUID")
    local _, t_str = reaper.GetProjExtState(proj, EXT_SECTION, "TOTAL_TIME")
    local _, a_str = reaper.GetProjExtState(proj, EXT_SECTION, "ARRANGE_TIME")
    local _, p_str = reaper.GetProjExtState(proj, EXT_SECTION, "PLAYBACK_TIME")
    local _, fx_str = reaper.GetProjExtState(proj, EXT_SECTION, "PLUGINS")
    local _, d_str = reaper.GetProjExtState(proj, EXT_SECTION, "DAILY_LOG")

    if uuid_str == "" and t_str == "" then
        current_proj_uuid = generate_uuid()
        reaper.SetProjExtState(proj, EXT_SECTION, "PROJ_UUID", current_proj_uuid)
        total_time = 0.0
        arrange_time = 0.0
        playback_time = 0.0
        session_time = 0.0
        plugin_times = {}
        sorted_plugins = {}
        daily_times = {}
    else
        if uuid_str == "" then
            uuid_str = generate_uuid()
            reaper.SetProjExtState(proj, EXT_SECTION, "PROJ_UUID", uuid_str)
        end
        current_proj_uuid = uuid_str
        total_time = tonumber(t_str) or 0.0
        arrange_time = tonumber(a_str) or 0.0
        playback_time = tonumber(p_str) or 0.0
        session_time = 0.0
        plugin_times = deserialize_table(fx_str)
        daily_times = deserialize_table(d_str)
        rebuild_sorted_plugins()
    end

    scroll_offset = 0
    plugins_dirty = false
    last_proj_change = reaper.GetProjectStateChangeCount(proj)
end

local function reset_project_data()
    total_time = 0.0
    arrange_time = 0.0
    playback_time = 0.0
    session_time = 0.0
    plugin_times = {}
    sorted_plugins = {}
    daily_times = {}
    scroll_offset = 0
    plugins_dirty = false
    save_project_data(current_proj, true)
end

-- Detects project switches. The cheap pointer comparison runs every frame;
-- the ExtState UUID scan for same-slot reloads is throttled (0.5 s). A real
-- project switch always changes the pointer, so it is detected instantly.
local function check_project_switch(now)
    local proj, proj_fn = reaper.EnumProjects(-1)

    if proj ~= current_proj then
        if current_proj and reaper.ValidatePtr(current_proj, "ReaProject*") then
            save_project_data(current_proj, false)
        end
        current_proj = proj
        current_proj_fn = proj_fn
        load_project_data(proj)
        return true
    end

    if (now - last_uuid_check) >= 0.5 then
        last_uuid_check = now
        local _, ext_uuid = reaper.GetProjExtState(proj, EXT_SECTION, "PROJ_UUID")
        if ext_uuid ~= current_proj_uuid then
            current_proj_fn = proj_fn
            load_project_data(proj)
            return true
        end
    end

    if proj_fn ~= current_proj_fn then
        current_proj_fn = proj_fn
    end

    return false
end

--------------------------------------------------------------------------------
-- CONTEXT, FOREGROUND & FOCUS DETECTION
--------------------------------------------------------------------------------

local function get_active_focused_fx()
    local retval, tracknum, itemnum, fxnum = reaper.GetFocusedFX()
    if retval == 0 then return false, nil end

    if retval == 1 then
        local track = (tracknum == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, tracknum - 1)
        if not track then return false, nil end

        local is_floating = reaper.TrackFX_GetOpen(track, fxnum)
        local chain_vis = reaper.TrackFX_GetChainVisible(track)
        local is_in_chain = (chain_vis ~= -1)

        if is_floating or is_in_chain then
            local ok, fx_name = reaper.TrackFX_GetFXName(track, fxnum, "")
            if ok and fx_name ~= "" then
                return true, clean_fx_name(fx_name)
            end
        end

    elseif retval == 2 then
        local track = reaper.GetTrack(0, tracknum - 1)
        if not track then return false, nil end
        local item = reaper.GetTrackMediaItem(track, itemnum)
        if not item then return false, nil end

        local take_idx = (fxnum >> 16) & 0xFFFF
        local actual_fx = fxnum & 0xFFFF
        local take = reaper.GetTake(item, take_idx)
        if not take then return false, nil end

        local is_floating = reaper.TakeFX_GetOpen(take, actual_fx)
        local chain_vis = reaper.TakeFX_GetChainVisible(take)
        local is_in_chain = (chain_vis ~= -1)

        if is_floating or is_in_chain then
            local ok, fx_name = reaper.TakeFX_GetFXName(take, actual_fx, "")
            if ok and fx_name ~= "" then
                return true, clean_fx_name(fx_name)
            end
        end

    elseif retval == 3 then
        -- REAPER 7+: focus on an FX inside a container (nested fxnum packing
        -- not decoded). Still counts as activity context; without a resolvable
        -- name the time falls into the arrangement bucket.
        return true, nil
    end

    return false, nil
end

-- Checks if a window handle belongs to the REAPER process (requires js_ReaScriptAPI)
local function is_hwnd_reaper(hwnd)
    if not hwnd then return false end
    local main_hwnd = reaper.GetMainHwnd()
    local cur = hwnd
    while cur do
        if cur == main_hwnd then return true end
        local parent = reaper.JS_Window_GetParent(cur)
        if not parent or parent == cur then break end
        cur = parent
    end
    local owner = reaper.JS_Window_GetRelated(hwnd, "OWNER")
    if owner and owner == main_hwnd then return true end
    return false
end

-- Ensures mouse movement is ONLY registered when REAPER is in foreground and hovered
local function is_mouse_valid_in_reaper(mx, my, fx_open, pt_found)
    -- Ignore cursor movements inside the tracker's own UI window
    local mouse_in_tracker = (gfx.mouse_x >= 0 and gfx.mouse_x <= gfx.w and gfx.mouse_y >= 0 and gfx.mouse_y <= gfx.h)
    if mouse_in_tracker then return false end

    -- 1. Precision check if js_ReaScriptAPI is installed
    if reaper.JS_Window_GetForeground then
        local fg_hwnd = reaper.JS_Window_GetForeground()
        if not fg_hwnd then return false end

        local fg_is_reaper = is_hwnd_reaper(fg_hwnd) or fx_open
        if not fg_is_reaper then
            return false
        end

        if reaper.JS_Window_FromPoint then
            local pt_hwnd = reaper.JS_Window_FromPoint(mx, my)
            if pt_hwnd and (is_hwnd_reaper(pt_hwnd) or fx_open) then
                return true
            end
            return false
        end
        return true
    end

    -- 2. Native REAPER fallback: cursor over a known REAPER UI element?
    -- (retval of GetThingFromPoint, now evaluated correctly)
    if pt_found then
        return true
    end

    -- Allow if a plugin window is open and actively focused in REAPER
    if fx_open then
        return true
    end

    return false
end

local function detect_working_context(fx_open, fx_name, pt_found, pt_info)
    -- (fx context comes from the per-frame probe in update_tracking)
    local mouse_in_arrange_area = false

    if pt_found and pt_info and pt_info ~= "" and not pt_info:match("^fx") then
        mouse_in_arrange_area = true
    end

    if fx_open and fx_name and not mouse_in_arrange_area then
        return "PLUGIN", fx_name
    else
        return "ARRANGEMENT", nil
    end
end

--------------------------------------------------------------------------------
-- CORE TIMING UPDATE LOOP
--------------------------------------------------------------------------------

local function update_tracking()
    local now = reaper.time_precise()
    local dt = now - last_time
    last_time = now

    if dt < 0 or dt > 1.0 then dt = 0 end

    -- Refresh the cached date string every 10 s (catches midnight rollover)
    if (now - last_today_check) >= 10.0 then
        today_str = get_today_str()
        last_today_check = now
    end

    if check_project_switch(now) then
        return
    end

    -- Cheap checks first: mouse position and playback state
    local mx, my = reaper.GetMousePosition()
    local coords_changed = (mx ~= last_mx or my ~= last_my)
    last_mx, last_my = mx, my

    local play_state = reaper.GetPlayState()
    local is_playing = ((play_state & 1) == 1) or ((play_state & 4) == 4)

    -- Combined context probe: ONE API pass per frame, only when the result
    -- can matter (mouse moved or tracking may be active)
    local fx_open, fx_name = false, nil
    local pt_found, pt_info = false, nil
    if coords_changed or is_playing or ((now - last_activity_ts) <= hold_time) then
        fx_open, fx_name = get_active_focused_fx()
        if reaper.GetThingFromPoint then
            local retval, _, info = reaper.GetThingFromPoint(mx, my)
            pt_found = (retval == true) or (info ~= nil and info ~= "")
            pt_info = info
        end
    end

    local mouse_moved = false
    if coords_changed and is_mouse_valid_in_reaper(mx, my, fx_open, pt_found) then
        mouse_moved = true
    end

    local proj_change = reaper.GetProjectStateChangeCount(0)
    local state_changed = (proj_change ~= last_proj_change)
    last_proj_change = proj_change

    if mouse_moved or state_changed then
        last_activity_ts = now
    end

    local is_input_active = ((now - last_activity_ts) <= hold_time)

    -- Flush a pending sorted-plugin rebuild (throttled to 1/s instead of
    -- rebuilding and re-sorting on every frame while a plugin is focused)
    if plugins_dirty and ((now - last_rebuild_ts) >= 1.0) then
        rebuild_sorted_plugins()
        plugins_dirty = false
        last_rebuild_ts = now
    end

    if is_paused then
        is_active = false
        status_text = "PAUSED"
        active_target_text = "Paused manually"
        return
    end

    is_active = is_playing or is_input_active

    if is_active then
        total_time = total_time + dt
        session_time = session_time + dt

        daily_times[today_str] = (daily_times[today_str] or 0.0) + dt

        if is_playing then
            playback_time = playback_time + dt
        end

        if is_playing and is_input_active then
            status_text = "ACTIVE (PLAY + EDIT)"
        elseif is_playing then
            status_text = "ACTIVE (PLAYBACK)"
        else
            status_text = "ACTIVE (MOUSE / EDIT)"
        end

        local ctx, ctx_fx = detect_working_context(fx_open, fx_name, pt_found, pt_info)
        if ctx == "PLUGIN" and ctx_fx then
            plugin_times[ctx_fx] = (plugin_times[ctx_fx] or 0.0) + dt
            active_target_text = ctx_fx
            plugins_dirty = true
        else
            arrange_time = arrange_time + dt
            active_target_text = "Arrangement View"
        end

        -- Persist to project RAM every SAVE_INTERVAL; raise the dirty flag
        -- at most every DIRTY_INTERVAL so save prompts stay rare
        if (now - last_save_ts) >= SAVE_INTERVAL then
            local mark_dirty = ((now - last_dirty_ts) >= DIRTY_INTERVAL)
            save_project_data(current_proj, mark_dirty)
            if mark_dirty then last_dirty_ts = now end
            last_save_ts = now
        end
    else
        status_text = "IDLE"
        active_target_text = "Waiting for playback or mouse..."
    end
end

--------------------------------------------------------------------------------
-- UI DRAWING HELPERS
--------------------------------------------------------------------------------

local function set_color(r, g, b, a)
    gfx.set(r / 255, g / 255, b / 255, a or 1.0)
end

local function point_in_rect(px, py, x, y, w, h)
    return px >= x and px <= (x + w) and py >= y and py <= (y + h)
end

local function draw_button(x, y, w, h, label, active_color, is_toggled, mouse_clicked, font_slot)
    local hover = point_in_rect(gfx.mouse_x, gfx.mouse_y, x, y, w, h)

    if is_toggled then
        set_color(active_color[1], active_color[2], active_color[3], 0.85)
    elseif hover then
        set_color(65, 70, 80, 1.0)
    else
        set_color(45, 48, 55, 1.0)
    end
    gfx.rect(x, y, w, h, 1)

    set_color(90, 95, 105, 1.0)
    gfx.rect(x, y, w, h, 0)

    set_color(235, 238, 242, 1.0)
    gfx.setfont(font_slot)
    local tw, th = gfx.measurestr(label)
    gfx.x = x + (w - tw) * 0.5
    gfx.y = y + (h - th) * 0.5
    gfx.drawstr(label)

    return hover and mouse_clicked
end

-- Determines GitHub shade level (0..4) for a given day's seconds relative to max_sec
local function get_heatmap_level(sec, max_sec)
    if not sec or sec <= 0 then return 0 end
    if max_sec <= 0 then return 1 end
    local ratio = sec / max_sec
    if ratio <= 0.25 then return 1
    elseif ratio <= 0.50 then return 2
    elseif ratio <= 0.75 then return 3
    else return 4 end
end

--------------------------------------------------------------------------------
-- HEATMAP RENDERING
--------------------------------------------------------------------------------

local function draw_heatmap_view(x, y, w, h, scale, mouse_clicked)
    local inner_pad = math.floor(10 * scale)
    local cx = x + inner_pad
    local cy = y + inner_pad
    local cw = w - inner_pad * 2

    -- 1. Month Navigation Bar
    local nav_h = math.floor(22 * scale)
    local nav_btn_w = math.floor(28 * scale)
    local today_btn_w = math.floor(54 * scale)

    if draw_button(cx, cy, nav_btn_w, nav_h, "<", { 60, 130, 180 }, false, mouse_clicked, 3) then
        step_month(-1)
    end

    if draw_button(cx + nav_btn_w + math.floor(4 * scale), cy, nav_btn_w, nav_h, ">", { 60, 130, 180 }, false, mouse_clicked, 3) then
        step_month(1)
    end

    if draw_button(cx + cw - today_btn_w, cy, today_btn_w, nav_h, "Today", { 60, 130, 180 }, false, mouse_clicked, 3) then
        local now_t = os.date("*t")
        view_year = now_t.year
        view_month = now_t.month
        selected_date_str = get_today_str()
    end

    -- Centered Month + Year Title
    gfx.setfont(2)
    set_color(230, 235, 242, 1.0)
    local month_title = string.format("%s %d", MONTH_NAMES[view_month], view_year)
    local mtw, mth = gfx.measurestr(month_title)
    gfx.x = cx + (cw - mtw) * 0.5
    gfx.y = cy + (nav_h - mth) * 0.5
    gfx.drawstr(month_title)

    cy = cy + nav_h + math.floor(8 * scale)

    -- 2. Weekday Headers (Mo .. Su)
    local cell_gap = math.max(2, math.floor(4 * scale))
    local cell_w = math.floor((cw - cell_gap * 6) / 7)
    local wk_h = math.floor(16 * scale)

    gfx.setfont(3)
    set_color(140, 148, 162, 1.0)
    for col = 1, 7 do
        local wx = cx + (col - 1) * (cell_w + cell_gap)
        local ltw, _ = gfx.measurestr(WEEKDAY_LABELS[col])
        gfx.x = wx + (cell_w - ltw) * 0.5
        gfx.y = cy
        gfx.drawstr(WEEKDAY_LABELS[col])
    end

    cy = cy + wk_h + math.floor(4 * scale)

    -- 3. Calculate Month Statistics & Grid Dimensions
    local days_in_month, first_wday = get_month_layout(view_year, view_month)
    local total_slots = (first_wday - 1) + days_in_month
    local num_rows = math.ceil(total_slots / 7)

    local max_day_sec = 0.0
    local month_total_sec = 0.0
    local month_day_strs, month_day_secs = {}, {}
    for d = 1, days_in_month do
        local d_str = string.format("%04d-%02d-%02d", view_year, view_month, d)
        local sec = daily_times[d_str] or 0.0
        month_day_strs[d] = d_str
        month_day_secs[d] = sec
        month_total_sec = month_total_sec + sec
        if sec > max_day_sec then
            max_day_sec = sec
        end
    end

    local footer_h = math.floor(38 * scale)
    local avail_grid_h = (y + h - inner_pad - footer_h) - cy
    local cell_h = math.max(math.floor(16 * scale), math.floor((avail_grid_h - cell_gap * (num_rows - 1)) / num_rows))

    -- 4. Draw Day Cells
    gfx.setfont(3)
    for d = 1, days_in_month do
        local slot = (first_wday - 1) + (d - 1)
        local col = slot % 7
        local row = math.floor(slot / 7)

        local cell_x = cx + col * (cell_w + cell_gap)
        local cell_y = cy + row * (cell_h + cell_gap)

        local d_str = month_day_strs[d]
        local sec = month_day_secs[d]
        local lvl = get_heatmap_level(sec, max_day_sec)
        local col_rgb = HEATMAP_COLORS[lvl]

        set_color(col_rgb[1], col_rgb[2], col_rgb[3], 1.0)
        gfx.rect(cell_x, cell_y, cell_w, cell_h, 1)

        local is_hover = point_in_rect(gfx.mouse_x, gfx.mouse_y, cell_x, cell_y, cell_w, cell_h)
        if is_hover and mouse_clicked then
            selected_date_str = d_str
        end

        if d_str == selected_date_str then
            set_color(250, 250, 255, 1.0)
            gfx.rect(cell_x, cell_y, cell_w, cell_h, 0)
            gfx.rect(cell_x + 1, cell_y + 1, cell_w - 2, cell_h - 2, 0)
        elseif d_str == today_str then
            set_color(90, 170, 240, 0.9)
            gfx.rect(cell_x, cell_y, cell_w, cell_h, 0)
        elseif is_hover then
            set_color(150, 160, 175, 0.8)
            gfx.rect(cell_x, cell_y, cell_w, cell_h, 0)
        else
            set_color(24, 26, 30, 0.6)
            gfx.rect(cell_x, cell_y, cell_w, cell_h, 0)
        end

        local day_label = tostring(d)
        local dtw, dth = gfx.measurestr(day_label)
        if lvl >= 3 then
            set_color(15, 20, 15, 1.0)
        elseif lvl >= 1 then
            set_color(235, 245, 238, 1.0)
        else
            set_color(145, 152, 165, 1.0)
        end
        gfx.x = cell_x + (cell_w - dtw) * 0.5
        gfx.y = cell_y + (cell_h - dth) * 0.5
        gfx.drawstr(day_label)
    end

    -- 5. Bottom Inspector & Color Legend Bar
    local foot_y = y + h - inner_pad - footer_h + math.floor(4 * scale)
    set_color(36, 40, 47, 1.0)
    gfx.rect(cx, foot_y, cw, footer_h - math.floor(4 * scale), 1)
    set_color(55, 62, 72, 1.0)
    gfx.rect(cx, foot_y, cw, footer_h - math.floor(4 * scale), 0)

    local sel_sec = daily_times[selected_date_str] or 0.0
    local sel_pct = (month_total_sec > 0) and math.floor((sel_sec / month_total_sec) * 100 + 0.5) or 0
    local info_str = string.format("%s:  %s  (%d%% of month)", selected_date_str, format_time(sel_sec), sel_pct)

    gfx.setfont(3)
    set_color(230, 235, 242, 1.0)
    local _, ith = gfx.measurestr(info_str)
    gfx.x = cx + math.floor(10 * scale)
    gfx.y = foot_y + ((footer_h - math.floor(4 * scale)) - ith) * 0.5
    gfx.drawstr(info_str)

    local sq_sz = math.max(8, math.floor(10 * scale))
    local sq_gap = math.max(2, math.floor(3 * scale))
    local more_w, _ = gfx.measurestr("More")
    local less_w, _ = gfx.measurestr("Less")
    local legend_total_w = less_w + sq_gap * 2 + (5 * sq_sz + 4 * sq_gap) + sq_gap * 2 + more_w

    if cw - legend_total_w > math.floor(210 * scale) then
        local lx = cx + cw - legend_total_w - math.floor(8 * scale)
        local ly = foot_y + ((footer_h - math.floor(4 * scale)) - sq_sz) * 0.5

        set_color(140, 148, 162, 1.0)
        gfx.x = lx
        gfx.y = foot_y + ((footer_h - math.floor(4 * scale)) - ith) * 0.5
        gfx.drawstr("Less")

        lx = lx + less_w + sq_gap * 2
        for lvl = 0, 4 do
            local c = HEATMAP_COLORS[lvl]
            set_color(c[1], c[2], c[3], 1.0)
            gfx.rect(lx, ly, sq_sz, sq_sz, 1)
            lx = lx + sq_sz + sq_gap
        end

        set_color(140, 148, 162, 1.0)
        gfx.x = lx + sq_gap
        gfx.y = foot_y + ((footer_h - math.floor(4 * scale)) - ith) * 0.5
        gfx.drawstr("More")
    end
end

--------------------------------------------------------------------------------
-- MAIN UI RENDER LOOP
--------------------------------------------------------------------------------

local function draw_ui()
    local w, h = gfx.w, gfx.h
    -- pending_click catches presses that happened on skipped (throttled) frames
    local mouse_clicked = (((gfx.mouse_cap & 1) == 1) and ((last_mouse_cap & 1) == 0)) or pending_click
    pending_click = false
    last_mouse_cap = gfx.mouse_cap

    local scale = math.min(w / BASE_W, h / BASE_H)
    scale = math.max(0.75, math.min(1.8, scale))

    gfx.setfont(1, "Consolas", math.floor(38 * scale), "b")
    gfx.setfont(2, "Segoe UI", math.floor(15 * scale), "b")
    gfx.setfont(3, "Segoe UI", math.floor(13 * scale), 0)

    set_color(24, 26, 30, 1.0)
    gfx.rect(0, 0, w, h, 1)

    local pad = math.floor(14 * scale)
    local inner_w = w - pad * 2
    local y = pad

    -- 1. Top Header Bar & Controls
    gfx.setfont(2)
    set_color(200, 205, 215, 1.0)
    gfx.x = pad
    gfx.y = y + math.floor(3 * scale)
    gfx.drawstr("PROJECT TIME TRACKER")

    local btn_w = math.floor(58 * scale)
    local btn_h = math.floor(22 * scale)
    local reset_x = w - pad - btn_w
    local edit_x = reset_x - btn_w - math.floor(6 * scale)
    local hold_x = edit_x - btn_w - math.floor(6 * scale)
    local pause_x = hold_x - btn_w - math.floor(6 * scale)

    if draw_button(pause_x, y, btn_w, btn_h, is_paused and "Resume" or "Pause", { 200, 130, 40 }, is_paused, mouse_clicked, 3) then
        is_paused = not is_paused
    end

    if draw_button(hold_x, y, btn_w, btn_h, "Hold: " .. hold_time .. "s", { 60, 130, 180 }, false, mouse_clicked, 3) then
        hold_idx = (hold_idx % #HOLD_OPTIONS) + 1
        hold_time = HOLD_OPTIONS[hold_idx]
    end

    if draw_button(edit_x, y, btn_w, btn_h, "Edit", { 80, 160, 110 }, false, mouse_clicked, 3) then
        local target_day = selected_date_str or get_today_str()
        local prompt_title = "Add/Subtract Time (Minutes) [" .. target_day .. "]"
        local ok, csv = reaper.GetUserInputs(prompt_title, 3, "Total / Selected Day (min):,Arrangement (min):,Playback (min):", "0,0,0")
        if ok then
            local add_total, add_arrange, add_play = csv:match("([^,]+),([^,]+),([^,]+)")
            add_total = tonumber(add_total) or 0
            add_arrange = tonumber(add_arrange) or 0
            add_play = tonumber(add_play) or 0

            local delta_sec = add_total * 60
            total_time = math.max(0, total_time + delta_sec)
            arrange_time = math.max(0, arrange_time + (add_arrange * 60))
            playback_time = math.max(0, playback_time + (add_play * 60))
            daily_times[target_day] = math.max(0, (daily_times[target_day] or 0.0) + delta_sec)

            save_project_data(current_proj, true)
        end
        last_time = reaper.time_precise()
    end

    if draw_button(reset_x, y, btn_w, btn_h, "Reset", { 180, 60, 60 }, false, mouse_clicked, 3) then
        local confirm = reaper.ShowMessageBox("Reset all tracked time for this project?", "Project Time Tracker", 4)
        if confirm == 6 then
            reset_project_data()
        end
        last_time = reaper.time_precise()
    end

    y = y + math.floor(32 * scale)

    -- 2. Main Timer Card
    local card_h = math.floor(92 * scale)
    set_color(34, 37, 43, 1.0)
    gfx.rect(pad, y, inner_w, card_h, 1)
    set_color(55, 60, 70, 1.0)
    gfx.rect(pad, y, inner_w, card_h, 0)

    local dot_r = math.floor(5 * scale)
    local dot_x = pad + math.floor(16 * scale)
    local dot_y = y + math.floor(18 * scale)
    if is_paused then
        set_color(230, 160, 50, 1.0)
    elseif is_active then
        set_color(70, 210, 110, 1.0)
    else
        set_color(120, 125, 135, 1.0)
    end
    gfx.circle(dot_x, dot_y, dot_r, 1, 1)

    gfx.setfont(3)
    set_color(170, 175, 185, 1.0)
    gfx.x = dot_x + math.floor(12 * scale)
    gfx.y = dot_y - math.floor(7 * scale)
    gfx.drawstr(status_text)

    local target_str = utf8_truncate(active_target_text, 28)
    local t_w, _ = gfx.measurestr(target_str)
    set_color(130, 140, 155, 1.0)
    gfx.x = w - pad - math.floor(12 * scale) - t_w
    gfx.y = dot_y - math.floor(7 * scale)
    gfx.drawstr(target_str)

    gfx.setfont(1)
    local main_time_str = format_time(total_time)
    local mtw, _ = gfx.measurestr(main_time_str)
    set_color(245, 248, 252, 1.0)
    gfx.x = pad + (inner_w - mtw) * 0.5
    gfx.y = y + math.floor(34 * scale)
    gfx.drawstr(main_time_str)

    y = y + card_h + math.floor(10 * scale)

    -- 3. Secondary Metric Boxes (Arrangement / Playback / Session)
    local box_gap = math.floor(8 * scale)
    local box_w = (inner_w - box_gap * 2) / 3
    local box_h = math.floor(56 * scale)

    local arr_pct = (total_time > 0) and math.floor((arrange_time / total_time) * 100 + 0.5) or 0
    local play_pct = (total_time > 0) and math.floor((playback_time / total_time) * 100 + 0.5) or 0

    local metrics = {
        { title = "ARRANGEMENT (" .. arr_pct .. "%)", val = format_time(arrange_time) },
        { title = "PLAYBACK (" .. play_pct .. "%)",   val = format_time(playback_time) },
        { title = "CURRENT SESSION",                  val = format_time(session_time) }
    }

    for i = 1, 3 do
        local bx = pad + (i - 1) * (box_w + box_gap)
        set_color(34, 37, 43, 1.0)
        gfx.rect(bx, y, box_w, box_h, 1)
        set_color(50, 55, 65, 1.0)
        gfx.rect(bx, y, box_w, box_h, 0)

        gfx.setfont(3)
        set_color(145, 152, 165, 1.0)
        gfx.x = bx + math.floor(10 * scale)
        gfx.y = y + math.floor(8 * scale)
        gfx.drawstr(metrics[i].title)

        gfx.setfont(2)
        set_color(230, 235, 242, 1.0)
        gfx.x = bx + math.floor(10 * scale)
        gfx.y = y + math.floor(28 * scale)
        gfx.drawstr(metrics[i].val)
    end

    y = y + box_h + math.floor(12 * scale)

    -- 4. View Switcher Tabs (PLUGINS vs. HEATMAP)
    local tab_gap = math.floor(6 * scale)
    local tab_w = math.floor((inner_w - tab_gap) * 0.5)
    local tab_h = math.floor(24 * scale)

    if draw_button(pad, y, tab_w, tab_h, string.format("PLUGINS (%d)", #sorted_plugins), { 55, 115, 175 }, active_tab == 1, mouse_clicked, 3) then
        active_tab = 1
    end

    if draw_button(pad + tab_w + tab_gap, y, inner_w - tab_w - tab_gap, tab_h, "MONTHLY HEATMAP", { 45, 145, 85 }, active_tab == 2, mouse_clicked, 3) then
        active_tab = 2
    end

    y = y + tab_h + math.floor(6 * scale)

    -- 5. Bottom Content Area (Plugin List OR Monthly Heatmap)
    local list_h = h - y - pad
    if list_h < 80 then list_h = 80 end

    set_color(30, 33, 38, 1.0)
    gfx.rect(pad, y, inner_w, list_h, 1)
    set_color(50, 55, 65, 1.0)
    gfx.rect(pad, y, inner_w, list_h, 0)

    if active_tab == 1 then
        -- TAB 1: Scrollable Plugin List
        local row_h = math.floor(28 * scale)
        local content_h = #sorted_plugins * row_h
        max_scroll = math.max(0, content_h - list_h)

        -- Keep the offset valid after window resizes (list got taller)
        if scroll_offset > max_scroll then scroll_offset = max_scroll end

        if gfx.mouse_wheel ~= 0 then
            if point_in_rect(gfx.mouse_x, gfx.mouse_y, pad, y, inner_w, list_h) then
                scroll_offset = scroll_offset - (gfx.mouse_wheel / 120) * row_h
                scroll_offset = math.max(0, math.min(max_scroll, scroll_offset))
            end
            gfx.mouse_wheel = 0
        end

        if #sorted_plugins == 0 then
            gfx.setfont(3)
            set_color(120, 125, 135, 1.0)
            local empty_msg = "No plugin focus time recorded yet."
            local ew, eh = gfx.measurestr(empty_msg)
            gfx.x = pad + (inner_w - ew) * 0.5
            gfx.y = y + (list_h - eh) * 0.5
            gfx.drawstr(empty_msg)
        else
            local max_plugin_time = sorted_plugins[1].time
            local visible_rows = math.floor(list_h / row_h)
            local first_idx = math.floor(scroll_offset / row_h) + 1
            local last_idx = math.min(#sorted_plugins, first_idx + visible_rows)

            for i = first_idx, last_idx do
                local item = sorted_plugins[i]
                local ry = y + (i - 1) * row_h - scroll_offset

                if ry >= y - 2 and (ry + row_h) <= (y + list_h + 2) then
                    if i % 2 == 0 then
                        set_color(36, 39, 45, 1.0)
                        gfx.rect(pad + 1, ry, inner_w - 2, row_h, 1)
                    end

                    local bar_ratio = (max_plugin_time > 0) and (item.time / max_plugin_time) or 0
                    local bar_w = math.floor((inner_w - 4) * bar_ratio)
                    set_color(55, 110, 165, 0.35)
                    gfx.rect(pad + 2, ry + 2, bar_w, row_h - 4, 1)

                    gfx.setfont(3)
                    set_color(225, 230, 238, 1.0)
                    local disp_name, name_trunc = utf8_truncate(item.name, 35)
                    if name_trunc then
                        disp_name = disp_name .. "..."
                    end
                    gfx.x = pad + math.floor(10 * scale)
                    gfx.y = ry + math.floor(6 * scale)
                    gfx.drawstr(disp_name)

                    local pct = (total_time > 0) and math.floor((item.time / total_time) * 100 + 0.5) or 0
                    local time_label = string.format("%s (%d%%)", format_time(item.time), pct)
                    local tlw, _ = gfx.measurestr(time_label)
                    set_color(175, 185, 200, 1.0)
                    gfx.x = pad + inner_w - tlw - math.floor(10 * scale)
                    gfx.y = ry + math.floor(6 * scale)
                    gfx.drawstr(time_label)
                end
            end
        end
    else
        -- TAB 2: Monthly GitHub-Style Heatmap
        gfx.mouse_wheel = 0
        draw_heatmap_view(pad, y, inner_w, list_h, scale, mouse_clicked)
    end

    gfx.update()
end

--------------------------------------------------------------------------------
-- INITIALIZATION & LIFECYCLE
--------------------------------------------------------------------------------

local function init()
    -- Guard against a second running instance (would double-count time).
    -- Non-persisted heartbeat ExtState: RAM-only, so a crashed previous run
    -- cannot leave a stale lock behind.
    local hb = tonumber(reaper.GetExtState(EXT_SECTION, "HEARTBEAT")) or 0
    if os.time() - hb < 5 then
        reaper.ShowMessageBox("Another instance of Project Time Tracker appears to be running in this REAPER session.\n\nThis second instance will not start (it would double-count tracked time).", "Project Time Tracker", 0)
        return false
    end

    math.randomseed(os.time())

    local dock = tonumber(reaper.GetExtState(WIN_SECTION, "DOCK")) or 0
    local wx = tonumber(reaper.GetExtState(WIN_SECTION, "X")) or 150
    local wy = tonumber(reaper.GetExtState(WIN_SECTION, "Y")) or 150
    local ww = tonumber(reaper.GetExtState(WIN_SECTION, "W")) or BASE_W
    local wh = tonumber(reaper.GetExtState(WIN_SECTION, "H")) or BASE_H

    gfx.init("Project Time Tracker", ww, wh, dock, wx, wy)

    current_proj, current_proj_fn = reaper.EnumProjects(-1)
    load_project_data(current_proj)
    return true
end

local function on_exit()
    if current_proj and reaper.ValidatePtr(current_proj, "ReaProject*") then
        save_project_data(current_proj, total_time > 0)
    end
    reaper.DeleteExtState(EXT_SECTION, "HEARTBEAT", false)
    local dock, wx, wy, ww, wh = gfx.dock(-1, 0, 0, 0, 0)
    reaper.SetExtState(WIN_SECTION, "DOCK", tostring(dock), true)
    reaper.SetExtState(WIN_SECTION, "X", tostring(wx), true)
    reaper.SetExtState(WIN_SECTION, "Y", tostring(wy), true)
    reaper.SetExtState(WIN_SECTION, "W", tostring(ww), true)
    reaper.SetExtState(WIN_SECTION, "H", tostring(wh), true)
    gfx.quit()
end

local function main_loop()
    local char = gfx.getchar()
    if char == -1 or char == 27 then
        return
    end

    if char == 32 then
        reaper.Main_OnCommand(40044, 0)
    end

    -- Catch mouse presses even on skipped (throttled) frames
    if (gfx.mouse_cap & 1) == 1 and (last_cap_check & 1) == 0 then
        pending_click = true
    end
    last_cap_check = gfx.mouse_cap

    -- Second-instance heartbeat (non-persisted, refreshed once per second)
    local now = reaper.time_precise()
    if (now - last_heartbeat_ts) >= 1.0 then
        reaper.SetExtState(EXT_SECTION, "HEARTBEAT", tostring(os.time()), false)
        last_heartbeat_ts = now
    end

    update_tracking()

    -- Redraw throttle: full rate while the mouse is over the window (hover
    -- feedback), throttled while it is outside (only the timer ticks there)
    local mouse_in_window = (gfx.mouse_x >= 0 and gfx.mouse_x < gfx.w and gfx.mouse_y >= 0 and gfx.mouse_y < gfx.h)
    if mouse_in_window or ((now - last_draw_ts) >= REDRAW_IDLE) then
        draw_ui()
        last_draw_ts = now
    end

    reaper.defer(main_loop)
end

if init() then
    reaper.atexit(on_exit)
    main_loop()
end
