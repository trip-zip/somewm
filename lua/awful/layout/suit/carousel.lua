---------------------------------------------------------------------------
--- Carousel (scrolling) layout for somewm.
--
-- Clients are arranged in columns on an infinite scrollable strip.
-- Each column has a configurable size fraction and can contain multiple
-- stacked clients. The viewport auto-scrolls to keep the focused column
-- visible.
--
-- Two orientations are available:
--   awful.layout.suit.carousel            -- horizontal (default)
--   awful.layout.suit.carousel.vertical   -- vertical
--
-- This is a somewm-specific layout that uses `_set_geometry_silent()`
-- to position offscreen clients without triggering signal cascades or
-- screen reassignment.
--
-- @module awful.layout.suit.carousel
---------------------------------------------------------------------------

local capi = { client = client, screen = screen, awesome = awesome }
local math = math
local ascreen = require("awful.screen")

-- awful.layout is lazy-loaded: carousel is required during awful.layout init,
-- so a top-level require would be circular. We cache after first use.
local layout
local function get_layout()
    if not layout then layout = require("awful.layout") end
    return layout
end

local _beautiful
local function get_beautiful()
    if not _beautiful then _beautiful = require("beautiful") end
    return _beautiful
end

local carousel = {}

--- The carousel layout layoutbox icon.
-- @beautiful beautiful.layout_carousel
-- @param surface
-- @see gears.surface

--- Default column width fraction for new columns.
-- @beautiful beautiful.carousel_default_column_width
-- @tparam[opt=1.0] number width_fraction

carousel.name = "carousel"

--- Default column width fraction (overridable via beautiful).
carousel.default_column_width = 1.0

--- Width presets for cycle_column_width().
carousel.width_presets = { 1/3, 1/2, 2/3, 1.0 }

--- Viewport centering modes:
-- - "never": only scroll when focused column would be completely offscreen
-- - "always": always center focused column
-- - "on-overflow" (default): center if focused column would be partially offscreen
-- - "edge": scroll just enough to bring focused column into view, aligned to nearest edge
carousel.center_mode = "on-overflow"

--- Scroll animation duration in seconds (0 = instant snap).
carousel.scroll_duration = 0.2

--- Peek width in pixels for showing adjacent column edges.
-- @beautiful beautiful.carousel_peek_width
-- @tparam[opt=0] number peek_width
carousel.peek_width = 0

-- Per-tag state, weak-keyed so it's collected when tags are removed.
local tag_state = setmetatable({}, { __mode = "k" })

local function get_state(t)
    if not tag_state[t] then
        tag_state[t] = {
            scroll_offset = 0,
            target_offset = 0,
            columns = {},
            client_to_column = setmetatable({}, { __mode = "k" }),
            -- Cached layout geometry (set during arrange, used by animation)
            col_positions = nil,
            workarea = nil,
            gap = 0,
            vertical = false,
            peek = 0,
            -- Animation state (C-side handle)
            anim_handle = nil,
        }
    end
    return tag_state[t]
end

local function clamp(val, lo, hi)
    return math.max(lo, math.min(hi, val))
end

--- Compute effective viewport after subtracting peek zones.
local function effective_viewport_size(viewport_size, peek)
    return math.max(1, viewport_size - 2 * peek)
end

--- Build a set from an array for O(1) lookups.
local function make_set(arr)
    local s = {}
    for _, v in ipairs(arr) do
        s[v] = true
    end
    return s
end

---------------------------------------------------------------------------
-- Axis abstraction helpers
---------------------------------------------------------------------------

--- Return the scroll-axis origin of the workarea.
-- Horizontal: x, Vertical: y
local function scroll_origin(wa, vertical)
    return vertical and wa.y or wa.x
end

--- Return the scroll-axis extent of the workarea.
-- Horizontal: width, Vertical: height
local function scroll_extent(wa, vertical)
    return vertical and wa.height or wa.width
end

--- Return the stack-axis origin of the workarea.
-- Horizontal: y, Vertical: x
local function stack_origin(wa, vertical)
    return vertical and wa.x or wa.y
end

--- Return the stack-axis extent of the workarea.
-- Horizontal: height, Vertical: width
local function stack_extent(wa, vertical)
    return vertical and wa.width or wa.height
end

---------------------------------------------------------------------------
-- Column/client state
---------------------------------------------------------------------------

--- Rebuild the client_to_column index from columns.
local function rebuild_index(state)
    local idx = state.client_to_column
    for k in pairs(idx) do
        idx[k] = nil
    end
    for col_idx, col in ipairs(state.columns) do
        for row_idx, c in ipairs(col.clients) do
            idx[c] = { col_idx = col_idx, row_idx = row_idx }
        end
    end
end

--- Find which column the focused client is in. Returns col_idx or nil.
local function focused_col_idx(state, focus)
    if not focus then return nil end
    local entry = state.client_to_column[focus]
    if entry then return entry.col_idx end
    return nil
end

--- Reconcile column state against the current tiled client list.
-- p.clients is authoritative: remove dead clients, add new ones.
local function reconcile(state, cls, default_width, focus)
    local live = make_set(cls)

    -- 1. Remove dead clients from columns, mark survivors as "placed"
    for _, col in ipairs(state.columns) do
        local j = 1
        for i = 1, #col.clients do
            if live[col.clients[i]] then
                live[col.clients[i]] = "placed"
                col.clients[j] = col.clients[i]
                j = j + 1
            end
        end
        for i = j, #col.clients do
            col.clients[i] = nil
        end
    end

    -- 2. Remove empty columns
    local j = 1
    for i = 1, #state.columns do
        if #state.columns[i].clients > 0 then
            state.columns[j] = state.columns[i]
            j = j + 1
        end
    end
    for i = j, #state.columns do
        state.columns[i] = nil
    end

    -- Rebuild index after compaction so focused_col_idx is accurate
    rebuild_index(state)

    -- 3. Add new clients as columns after focused
    local insert_after = focused_col_idx(state, focus) or #state.columns
    local added = 0

    for _, c in ipairs(cls) do
        if live[c] ~= "placed" then
            added = added + 1
            local new_col = {
                clients = { c },
                width_fraction = default_width,
            }
            table.insert(state.columns, insert_after + added, new_col)
        end
    end

    -- 4. Rebuild index
    rebuild_index(state)
end

---------------------------------------------------------------------------
-- Geometry computation
---------------------------------------------------------------------------

--- Compute column pixel positions on the canvas.
-- Returns array of {canvas_x, pixel_width} entries.
local function compute_column_positions(columns, wa_width)
    local positions = {}
    local x = 0
    for i, col in ipairs(columns) do
        local pw = math.floor(col.width_fraction * wa_width)
        positions[i] = { canvas_x = x, pixel_width = pw }
        x = x + pw
    end
    return positions
end

--- Total pixel width of the strip (left edge of first column to right edge
--- of last column, excluding trailing gap).
local function strip_width(col_positions)
    if #col_positions == 0 then return 0 end
    local last = col_positions[#col_positions]
    return last.canvas_x + last.pixel_width
end

--- Clamp scroll offset to strip boundaries.
-- If the strip is narrower than the viewport, center it.
local function clamp_offset(offset, col_positions, wa_width)
    if #col_positions == 0 then return 0 end
    local sw = strip_width(col_positions)
    if sw <= wa_width then
        return -(wa_width - sw) / 2
    end
    return clamp(offset, 0, sw - wa_width)
end

--- Compute scroll offset to center a column in the viewport.
local function offset_to_center_column(col_pos, wa_width)
    if not col_pos then return 0 end
    local center = col_pos.canvas_x + col_pos.pixel_width / 2
    return center - wa_width / 2
end

--- Apply geometry to all clients based on current scroll_offset.
-- This is the "render" step, separated from target computation so
-- the animation tick can call it independently. Reads all layout
-- geometry from the cached state fields (col_positions, workarea, gap).
local function apply_geometry(state)
    local col_positions = state.col_positions
    local wa = state.workarea
    local gap = state.gap
    if not col_positions or not wa then return end

    -- Debug hook: set carousel._perf = { enabled=true, now=os.clock, frames={} }
    -- to collect per-frame timing data in perf.frames[].duration_ms.
    local perf = carousel._perf
    local t0
    if perf and perf.enabled then
        t0 = perf.now()
    end

    local vert = state.vertical
    local peek = state.peek or 0
    local scroll_o = scroll_origin(wa, vert)
    local stack_o = stack_origin(wa, vert)
    local stack_sz = stack_extent(wa, vert)

    for ci, col in ipairs(state.columns) do
        local cp = col_positions[ci]
        if not cp then break end
        local n = #col.clients
        local stack_total = stack_sz - 2 * gap
        local row_size = math.floor((stack_total - (n - 1) * gap) / n)

        for ri, c in ipairs(col.clients) do
            local bw = c.border_width or 0
            local scroll_client_size = math.max(1, cp.pixel_width - 2 * bw - 2 * gap)
            local stack_client_size = math.max(1, row_size - 2 * bw)
            local stack_offset = (ri - 1) * (row_size + gap)
            local scroll_pos = scroll_o + peek + cp.canvas_x - state.scroll_offset + gap
            local stack_pos = stack_o + gap + stack_offset

            c:_set_geometry_silent({
                x      = vert and stack_pos or scroll_pos,
                y      = vert and scroll_pos or stack_pos,
                width  = vert and stack_client_size or scroll_client_size,
                height = vert and scroll_client_size or stack_client_size,
            })
        end
    end

    if perf and t0 then
        local t1 = perf.now()
        local frames = perf.frames
        frames[#frames + 1] = { time = t1, duration_ms = (t1 - t0) * 1000 }
    end
end

---------------------------------------------------------------------------
-- Animation
---------------------------------------------------------------------------

--- Stop any running scroll animation for this tag state.
local function stop_animation(state)
    if state.anim_handle then
        state.anim_handle:cancel()
        state.anim_handle = nil
    end
end

--- Start or retarget a scroll animation toward target_offset.
-- Uses C-side frame-synced animation for jitter-free delivery.
local function start_animation(state)
    local duration = carousel.scroll_duration

    -- Snap if animation disabled or distance negligible
    if duration <= 0 or math.abs(state.scroll_offset - state.target_offset) < 0.5 then
        stop_animation(state)
        state.scroll_offset = state.target_offset
        return
    end

    -- Cancel previous animation
    stop_animation(state)

    local start_val = state.scroll_offset
    local target_val = state.target_offset

    state.anim_handle = capi.awesome.start_animation(duration, "ease-out-cubic",
        function(progress)
            state.scroll_offset = start_val + (target_val - start_val) * progress
            apply_geometry(state)
        end,
        function()
            state.scroll_offset = target_val
            apply_geometry(state)
            state.anim_handle = nil
        end)
end

---------------------------------------------------------------------------
-- Layout arrange
---------------------------------------------------------------------------

--- Shared arrange implementation for both orientations.
-- @tparam table p Layout parameters from awful.layout.
-- @tparam boolean vertical True for vertical orientation.
function carousel._arrange_impl(p, vertical)
    local cls = p.clients
    if #cls == 0 then return end

    local wa = p.workarea
    local gap = p.useless_gap
    local scr = capi.screen[p.screen]
    local t = scr and scr.selected_tag
    if not t then return end

    local state = get_state(t)
    local focus = capi.client.focus

    -- Reconcile columns against live client list
    local default_width = get_beautiful().carousel_default_column_width
        or carousel.default_column_width
    reconcile(state, cls, default_width, focus)

    if #state.columns == 0 then return end

    local viewport_size = scroll_extent(wa, vertical)
    local peek = get_beautiful().carousel_peek_width or carousel.peek_width
    if peek < 0 then peek = 0 end
    local effective_viewport = effective_viewport_size(viewport_size, peek)
    local col_positions = compute_column_positions(state.columns, effective_viewport)

    -- Cache for animation and gesture use
    state.col_positions = col_positions
    state.workarea = wa
    state.gap = gap
    state.vertical = vertical
    state.peek = peek

    -- Compute target scroll offset based on centering mode
    local focus_ci = focused_col_idx(state, focus)
    if not focus_ci then focus_ci = 1 end
    state.last_focused_ci = focus_ci

    local fcp = col_positions[focus_ci]
    if carousel.center_mode == "always" then
        state.target_offset = offset_to_center_column(fcp, effective_viewport)
    elseif carousel.center_mode == "never" then
        -- Only scroll if focused column is completely offscreen
        local candidate = state.target_offset
        local near_edge = fcp.canvas_x - candidate
        local far_edge = near_edge + fcp.pixel_width
        if far_edge <= 0 then
            candidate = fcp.canvas_x
        elseif near_edge >= effective_viewport then
            candidate = fcp.canvas_x + fcp.pixel_width - effective_viewport
        end
        state.target_offset = candidate
    elseif carousel.center_mode == "edge" then
        local candidate = state.target_offset
        local near_edge = fcp.canvas_x - candidate
        local far_edge = near_edge + fcp.pixel_width
        if near_edge < 0 then
            candidate = fcp.canvas_x
        elseif far_edge > effective_viewport then
            candidate = fcp.canvas_x + fcp.pixel_width - effective_viewport
        end
        state.target_offset = candidate
    else -- "on-overflow" (default)
        local candidate = state.target_offset
        local near_edge = fcp.canvas_x - candidate
        local far_edge = near_edge + fcp.pixel_width
        if near_edge < 0 or far_edge > effective_viewport then
            candidate = offset_to_center_column(fcp, effective_viewport)
        end
        state.target_offset = candidate
    end

    -- Clamp to strip boundaries ("always" center mode is exempt so it
    -- can show empty space at strip edges when centering edge columns)
    local should_clamp = carousel.center_mode ~= "always"
    if should_clamp then
        state.target_offset = clamp_offset(
            state.target_offset, col_positions, effective_viewport)
        state.scroll_offset = clamp_offset(
            state.scroll_offset, col_positions, effective_viewport)
    end

    -- Animate or snap to target
    if carousel.scroll_duration > 0 then
        start_animation(state)
    else
        stop_animation(state)
        state.scroll_offset = state.target_offset
    end

    apply_geometry(state)
end

--- Carousel layout arrange function (horizontal).
-- @tparam table p Layout parameters from awful.layout.
function carousel.arrange(p)
    carousel._arrange_impl(p, false)
end

function carousel.skip_gap(nclients, t) -- luacheck: no unused args
    return true
end

--- Scroll the viewport by `n` columns worth of width.
-- Positive scrolls right, negative scrolls left.
-- @tparam tag t The tag.
-- @tparam number n Number of viewport-widths to scroll by.
function carousel.scroll_by(t, n)
    local state = get_state(t)
    local scr = t.screen
    if not scr then return end
    local wa = scr:get_bounding_geometry {
        honor_padding  = true,
        honor_workarea = true,
    }
    local viewport_size = scroll_extent(wa, state.vertical)
    local peek = state.peek or 0
    local effective_viewport = effective_viewport_size(viewport_size, peek)
    state.target_offset = state.target_offset + n * effective_viewport
    if state.col_positions then
        state.target_offset = clamp_offset(
            state.target_offset, state.col_positions, effective_viewport)
    end
    if carousel.scroll_duration > 0 and state.workarea then
        start_animation(state)
    else
        state.scroll_offset = state.target_offset
    end
end

---------------------------------------------------------------------------
-- Context helper for public API functions
---------------------------------------------------------------------------

--- Check if the given screen is using a carousel layout.
local function is_carousel_layout(s)
    local l = get_layout().get(s)
    return l == carousel or l == carousel.vertical
end

local function get_carousel_context()
    local s = ascreen.focused()
    local t = s and s.selected_tag
    if not t or not is_carousel_layout(s) then return nil end
    return get_state(t), s
end

--- Run a callback with the focused column, then re-arrange.
local function with_focused_column(fn)
    local state, s = get_carousel_context()
    if not state then return end

    local focus = capi.client.focus
    local ci = focused_col_idx(state, focus)
    if not ci then return end

    fn(state.columns[ci])
    get_layout().arrange(s)
end

---------------------------------------------------------------------------
-- Column Width Operations
---------------------------------------------------------------------------

--- Cycle the focused column's width through presets.
function carousel.cycle_column_width()
    with_focused_column(function(col)
        local presets = carousel.width_presets
        local eps = 0.01

        local current_idx = nil
        for i, p in ipairs(presets) do
            if math.abs(col.width_fraction - p) < eps then
                current_idx = i
                break
            end
        end

        local next_idx
        if current_idx then
            next_idx = (current_idx % #presets) + 1
        else
            next_idx = 1
        end
        col.width_fraction = presets[next_idx]
    end)
end

--- Adjust the focused column's width by a delta fraction.
-- @tparam number delta Fraction to add (e.g. 0.1 or -0.1).
function carousel.adjust_column_width(delta)
    with_focused_column(function(col)
        col.width_fraction = clamp(col.width_fraction + delta, 0.1, 2.0)
    end)
end

--- Set the focused column's width to an exact fraction.
-- @tparam number fraction The width fraction to set.
function carousel.set_column_width(fraction)
    with_focused_column(function(col)
        col.width_fraction = clamp(fraction, 0.1, 2.0)
    end)
end

--- Maximize the focused column to full width.
function carousel.maximize_column()
    with_focused_column(function(col)
        col.width_fraction = 1.0
    end)
end

---------------------------------------------------------------------------
-- Vertical Stacking (Consume/Expel)
---------------------------------------------------------------------------

--- Pull the focused window from an adjacent column into the focused column.
-- The adjacent column's first window is moved into the current column,
-- stacking vertically. If the adjacent column becomes empty, it is removed.
-- @tparam number dir Direction: -1 for left, 1 for right.
function carousel.consume_window(dir)
    local state, s = get_carousel_context()
    if not state then return end

    local focus = capi.client.focus
    if not focus then return end

    local entry = state.client_to_column[focus]
    if not entry then return end

    local source_ci = entry.col_idx + dir
    if source_ci < 1 or source_ci > #state.columns then return end

    local source_col = state.columns[source_ci]
    if #source_col.clients == 0 then return end

    local consumed = table.remove(source_col.clients, 1)
    local target_col = state.columns[entry.col_idx]
    table.insert(target_col.clients, consumed)

    if #source_col.clients == 0 then
        table.remove(state.columns, source_ci)
    end

    rebuild_index(state)
    get_layout().arrange(s)
end

--- Move the focused window out of its column into a new column.
-- If the focused column has only one window, this is a no-op.
-- The new column is inserted after the current column with the same width.
function carousel.expel_window()
    local state, s = get_carousel_context()
    if not state then return end

    local focus = capi.client.focus
    if not focus then return end

    local entry = state.client_to_column[focus]
    if not entry then return end

    local col = state.columns[entry.col_idx]
    if #col.clients <= 1 then return end

    table.remove(col.clients, entry.row_idx)

    local new_col = {
        clients = { focus },
        width_fraction = col.width_fraction,
    }
    table.insert(state.columns, entry.col_idx + 1, new_col)

    rebuild_index(state)
    get_layout().arrange(s)
end

--- Move the focused client into the adjacent column.
-- The client is removed from its current column and appended to the target
-- column's stack. If the source column becomes empty, it is removed.
-- This is the complement of consume_window (push vs pull).
-- @tparam number dir Direction: -1 for left, 1 for right.
function carousel.push_window(dir)
    local state, s = get_carousel_context()
    if not state then return end

    local focus = capi.client.focus
    if not focus then return end

    local entry = state.client_to_column[focus]
    if not entry then return end

    local target_ci = entry.col_idx + dir
    if target_ci < 1 or target_ci > #state.columns then return end

    local source_col = state.columns[entry.col_idx]
    local target_col = state.columns[target_ci]

    table.remove(source_col.clients, entry.row_idx)
    table.insert(target_col.clients, focus)

    if #source_col.clients == 0 then
        table.remove(state.columns, entry.col_idx)
    end

    rebuild_index(state)
    get_layout().arrange(s)
end

---------------------------------------------------------------------------
-- Column Movement
---------------------------------------------------------------------------

--- Swap the focused column with its neighbor in strip order.
-- @tparam number dir Direction: -1 for left, 1 for right.
function carousel.move_column(dir)
    local state, s = get_carousel_context()
    if not state or #state.columns < 2 then return end

    local focus = capi.client.focus
    local ci = focused_col_idx(state, focus)
    if not ci then return end

    local target = ci + dir
    if target < 1 or target > #state.columns then return end

    state.columns[ci], state.columns[target] = state.columns[target], state.columns[ci]

    rebuild_index(state)
    get_layout().arrange(s)
end

---------------------------------------------------------------------------
-- Column Edge Focus
---------------------------------------------------------------------------

--- Focus the first client in the column at a given index.
-- @tparam number col_idx Column index (1-based).
local function focus_column_at(col_idx)
    local state = get_carousel_context()
    if not state or col_idx < 1 or col_idx > #state.columns then return end
    local c = state.columns[col_idx].clients[1]
    if c then capi.client.focus = c; c:raise() end
end

--- Focus the first client in the first column.
function carousel.focus_first_column()
    focus_column_at(1)
end

--- Focus the first client in the last column.
function carousel.focus_last_column()
    local state = get_carousel_context()
    if not state then return end
    focus_column_at(#state.columns)
end

---------------------------------------------------------------------------
-- Centering Mode
---------------------------------------------------------------------------

--- Set the viewport centering mode.
-- @tparam string mode One of "never", "always", "on-overflow", "edge".
function carousel.set_center_mode(mode)
    assert(mode == "never" or mode == "always" or mode == "on-overflow" or mode == "edge",
        "Invalid center mode: " .. tostring(mode))
    carousel.center_mode = mode

    local state, s = get_carousel_context()
    if state then
        get_layout().arrange(s)
    end
end

---------------------------------------------------------------------------
-- Gesture Scrolling
---------------------------------------------------------------------------

--- Create a gesture binding for 3-finger swipe viewport panning.
-- During the swipe, the viewport tracks finger movement 1:1 (direct control).
-- On release, the viewport animates to snap the nearest column to a clean
-- position and focuses that column's first client.
-- @tparam[opt=false] boolean vertical Use vertical (dy) swipe axis.
-- @treturn table The awful.gesture binding object (call :remove() to unbind).
local function _make_gesture_binding(vertical)
    local gesture = require("awful.gesture")

    local swipe_start_offset = 0
    local swipe_tag = nil
    local expected_layout = vertical and carousel.vertical or carousel

    return gesture {
        type = "swipe",
        fingers = 3,
        description = vertical and "Carousel vertical viewport pan"
            or "Carousel viewport pan",
        group = "carousel",

        on_trigger = function()
            local s = ascreen.focused()
            local t = s and s.selected_tag
            if not t or get_layout().get(s) ~= expected_layout then return end

            swipe_tag = t
            local ts = get_state(t)
            stop_animation(ts)
            swipe_start_offset = ts.scroll_offset
        end,

        on_update = function(gs)
            if not swipe_tag then return end
            local ts = get_state(swipe_tag)
            if not ts.col_positions or not ts.workarea then return end

            local delta = vertical and gs.dy or gs.dx
            local viewport_size = scroll_extent(ts.workarea, vertical)
            local peek = ts.peek or 0
            local effective_viewport = effective_viewport_size(viewport_size, peek)
            local new_offset = swipe_start_offset - delta
            ts.scroll_offset = clamp_offset(
                new_offset, ts.col_positions, effective_viewport)
            ts.target_offset = ts.scroll_offset
            apply_geometry(ts)
        end,

        on_end = function()
            if not swipe_tag then return end
            local ts = get_state(swipe_tag)
            if not ts.col_positions or not ts.workarea then
                swipe_tag = nil
                return
            end

            local viewport_size = scroll_extent(ts.workarea, vertical)
            local peek = ts.peek or 0
            local effective_viewport = effective_viewport_size(viewport_size, peek)

            -- Find column nearest viewport center
            local vp_center = ts.scroll_offset + effective_viewport / 2
            local best_ci = 1
            local best_dist = math.huge
            for i, cp in ipairs(ts.col_positions) do
                local col_center = cp.canvas_x + cp.pixel_width / 2
                local dist = math.abs(col_center - vp_center)
                if dist < best_dist then
                    best_dist = dist
                    best_ci = i
                end
            end

            -- Animate to center that column
            local fcp = ts.col_positions[best_ci]
            ts.target_offset = offset_to_center_column(fcp, effective_viewport)
            ts.target_offset = clamp_offset(
                ts.target_offset, ts.col_positions, effective_viewport)

            if carousel.scroll_duration > 0 then
                start_animation(ts)
            else
                ts.scroll_offset = ts.target_offset
                apply_geometry(ts)
            end

            -- Focus the nearest column's first client
            local col = ts.columns[best_ci]
            if col and col.clients[1] then
                capi.client.focus = col.clients[1]
                col.clients[1]:raise()
            end

            swipe_tag = nil
        end,
    }
end

function carousel.make_gesture_binding()
    return _make_gesture_binding(false)
end

---------------------------------------------------------------------------
-- Auto-scroll viewport on focus change
---------------------------------------------------------------------------

-- Re-arrange when focus changes so the viewport scrolls to the newly
-- focused column. Skip if the focused column has not changed (e.g. focus
-- moved between rows in the same column, or refocused the same client).
capi.client.connect_signal("focus", function(c)
    local s = c.screen
    if not s then return end
    local t = s.selected_tag
    if not t or not is_carousel_layout(s) then return end

    local state = get_state(t)
    local ci = focused_col_idx(state, c)
    if ci == state.last_focused_ci then return end
    state.last_focused_ci = ci

    get_layout().arrange(s)
end)

---------------------------------------------------------------------------
-- Vertical sub-layout
---------------------------------------------------------------------------

--- Vertical carousel variant: clients scroll up/down instead of left/right.
-- @table carousel.vertical
carousel.vertical = {
    name = "carousel.vertical",
    skip_gap = carousel.skip_gap,
}

--- Vertical carousel arrange function.
-- @tparam table p Layout parameters from awful.layout.
function carousel.vertical.arrange(p)
    carousel._arrange_impl(p, true)
end

--- Create a gesture binding for vertical carousel swipe panning.
-- @treturn table The awful.gesture binding object.
function carousel.vertical.make_gesture_binding()
    return _make_gesture_binding(true)
end

-- Expose internals for unit testing (not part of the public API).
carousel._test = {
    compute_column_positions = compute_column_positions,
    strip_width = strip_width,
    clamp_offset = clamp_offset,
    offset_to_center_column = offset_to_center_column,
    reconcile = reconcile,
    get_state = get_state,
    rebuild_index = rebuild_index,
}

return carousel

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
