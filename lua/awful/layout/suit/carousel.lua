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
-- Clay solves the column tree and clips its scrollable strip to the viewport.
--
-- @module awful.layout.suit.carousel
---------------------------------------------------------------------------

local capi = { client = client }
local math = math
local ascreen = require("awful.screen")
local aclient = require("awful.client")

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

--- Viewport centering mode.
-- @beautiful beautiful.carousel_center_mode
-- @tparam[opt="on-overflow"] string center_mode

--- Viewport centering modes:
-- - "never": only scroll when focused column would be completely offscreen
-- - "always": always center focused column
-- - "on-overflow" (default): center if focused column would be partially offscreen
-- - "edge": scroll just enough to bring focused column into view, aligned to nearest edge
carousel.center_mode = "on-overflow"

--- Accepted for compatibility; client transitions use somewm.layout_animation.
carousel.scroll_duration = 0

--- Peek width in pixels for showing adjacent column edges.
-- @beautiful beautiful.carousel_peek_width
-- @tparam[opt=0] number peek_width
carousel.peek_width = 0

--- Dynamic peek width in pixels. Columns at the edges of the strip will have this applied
-- as their peek width. Negative values are ignored and cause edge columns to use
-- peek_width instead.
-- @beautiful beautiful.carousel_dynamic_peek
-- @tparam[opt=-1] number dynamic_peek_width
carousel.dynamic_peek_width = -1

-- Per-tag state, weak-keyed so it's collected when tags are removed.
local tag_state = setmetatable({}, { __mode = "k" })

local function get_state(t)
    if not tag_state[t] then
        tag_state[t] = {
            columns = {},
            client_to_column = setmetatable({}, { __mode = "k" }),
            vertical = false,
        }
    end
    return tag_state[t]
end

local function clamp(val, lo, hi)
    return math.max(lo, math.min(hi, val))
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

--- Return the scroll-axis extent of a solved box.
-- Horizontal: width, Vertical: height
local function scroll_extent(wa, vertical)
    return vertical and wa.height or wa.width
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

--- Find which row within a column the focused client is in. Returns row_idx or nil.
local function focused_row_idx(state, focus)
    if not focus then return nil end
    local entry = state.client_to_column[focus]
    if entry then return entry.row_idx end
    return nil
end

--- Reconcile column state against the current tiled client list.
-- The tiled client list is authoritative: remove dead clients, add new ones.
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
                width_fraction = c.carousel_column_width or default_width,
            }
            table.insert(state.columns, insert_after + added, new_col)
        end
    end

    -- 4. Rebuild index
    rebuild_index(state)
end

-- Build a private client-slot tree from reconciled membership. Column fractions
-- use the viewport inside peek padding. Centered end margins are percentages;
-- explicit lead and trail inputs are authored pixel margins.
-- Clay owns column allocation, alignment and the viewport scroll record.
function carousel._build_declarations(inputs)
    local vertical = inputs.vertical
    local axis, cross = vertical and "h" or "w", vertical and "w" or "h"
    local direction = vertical and "column" or "row"
    local gap, peek = inputs.gap or 0, inputs.peek or 0
    local children, columns = {}, {}
    local function margin(size)
        local item = { role = "CAROUSEL_MARGIN", children = {} }
        item[axis], item[cross] = size, 1
        children[#children + 1] = item
    end
    if inputs.centered and #inputs.columns > 0 then
        margin(math.max(0, (1 - inputs.columns[1].width_fraction) / 2))
    elseif (inputs.lead or 0) > 0 then
        margin({ fixed = inputs.lead })
    end
    for _, column in ipairs(inputs.columns) do
        local group = { role = "CAROUSEL_COLUMN",
            direction = vertical and "row" or "column",
            padding = gap, gap = 2 * gap, children = {} }
        group[axis], group[cross] = column.width_fraction, 1
        for _, c in ipairs(column.clients) do
            -- Protocol minima remain on the surface; they must not change
            -- column fractions or the equal allocation of grouped clients.
            local item = { client = c }
            item[axis], item[cross] = 1, 1 / #column.clients
            group.children[#group.children + 1] = item
        end
        children[#children + 1] = group
        columns[#columns + 1] = group
    end
    if inputs.centered and #inputs.columns > 0 then
        margin(math.max(0, (1 - inputs.columns[#inputs.columns].width_fraction) / 2))
    elseif (inputs.trail or 0) > 0 then
        margin({ fixed = inputs.trail })
    end
    return { role = "CAROUSEL_VIEWPORT", direction = direction,
        clip = vertical and "y" or "x", center = true,
        padding = vertical and { top = peek, bottom = peek } or { left = peek, right = peek },
        vertical = vertical, columns = columns, children = children }
end

carousel._native = {}

function carousel._native.target(mode, cs, cw, vw, r, dp)
    local near, far = cs - r, cs - r + cw
    if mode == "always" then
        return cs + cw / 2 - vw / 2
    elseif mode == "never" then
        if far <= 0 then return cs + dp end
        if near >= vw then return cs + cw - vw + dp end
        return r
    elseif mode == "edge" then
        if near < 0 then return cs + dp end
        if far > vw then return cs + cw - vw + dp end
        return r + dp
    else
        if near < 0 or far > vw then return cs + cw / 2 - vw / 2 end
        return r
    end
end

function carousel._native.pan(s, root, delta)
    if not root.id then return end
    local x, y, cw, ch, vw, vh = awesome._clay_scroll_get(s, root.id)
    if x == nil then return end
    local nx, ny = x, y
    if root.vertical then ny = y - delta else nx = x - delta end
    nx = math.min(math.max(nx, -math.max(cw - vw, 0)), 0)
    ny = math.min(math.max(ny, -math.max(ch - vh, 0)), 0)
    if nx ~= x or ny ~= y then
        awesome._clay_scroll_set(s, root.id, nx, ny)
    end
end

function carousel._native.follow(s, root, i, mode, dp)
    local column = root.columns[i]
    if not column or not column.box or not root.box or not root.scroll then return end
    local axis, extent = root.vertical and "y" or "x", root.vertical and "height" or "width"
    local x, y = awesome._clay_scroll_get(s, root.id)
    if x == nil then return end
    local r = -(root.vertical and y or x)
    local target = carousel._native.target(mode,
        column.box[axis] - root.box[axis] + r, column.box[extent], root.box[extent], r, dp)
    carousel._native.pan(s, root, target - r)
end

function carousel._native.nearest(s, root)
    local axis, extent = root.vertical and "y" or "x", root.vertical and "height" or "width"
    if not root.box then return end
    local center = root.box[axis] + root.box[extent] / 2
    local nearest, distance
    for i, column in ipairs(root.columns) do
        if column.box then
            local d = math.abs(column.box[axis] + column.box[extent] / 2 - center)
            if not distance or d < distance then nearest, distance = i, d end
        end
    end
    return nearest
end

---------------------------------------------------------------------------
-- Native layout declarations
---------------------------------------------------------------------------

local function describe(s, vertical)
    local t = s.selected_tag
    local state = get_state(t)
    local beautiful = get_beautiful()
    local focus = capi.client.focus
    reconcile(state, aclient.tiled(s),
        beautiful.carousel_default_column_width or carousel.default_column_width, focus)
    state.vertical = vertical

    local gap = t.gap_single_client == false and 0 or t.gap
    local peek = math.max(0, beautiful.carousel_peek_width or carousel.peek_width)
    if peek > 0 then peek = peek + gap end
    local dynamic_peek = beautiful.carousel_dynamic_peek_width or carousel.dynamic_peek_width
    local mode = beautiful.carousel_center_mode or carousel.center_mode
    local trail = 0
    local columns = state.columns
    local ci = focused_col_idx(state, focus)
        or math.min((state.last_focused_ci or 1) - 1, #columns)
    if ci == 0 then ci = nil end
    state.last_focused_ci = ci

    if #columns > 0 and (mode == "never" or mode == "edge")
            and dynamic_peek >= 0 and ci == #columns then
        local total = 0
        for _, column in ipairs(columns) do
            total = total + column.width_fraction
        end
        if total > 1 then trail = math.max(0, dynamic_peek + gap - peek) end
    end

    local tree = carousel._build_declarations {
        columns = columns, vertical = vertical,
        gap = gap, peek = peek, trail = trail,
        centered = #columns > 0 and mode == "always",
    }
    tree.peek, tree.dynamic_peek = peek, dynamic_peek

    -- Follow changed declarations once; scroll-only solves keep the same policy.
    local policy = { tostring(vertical), gap, peek, dynamic_peek, mode }
    for _, column in ipairs(columns) do
        policy[#policy + 1] = column.width_fraction
        for _, c in ipairs(column.clients) do policy[#policy + 1] = tostring(c) end
    end
    tree.policy = table.concat(policy, ":")
    if ci ~= state.followed_ci or not state.publish or state.publish.policy ~= tree.policy then
        state.pending_follow = true
    end

    return { role = "WORKAREA", direction = vertical and "column" or "row",
        padding = gap, children = { tree }, solved = function()
            state.publish = tree
            if not state.pending_follow then return end
            state.pending_follow = nil
            local dp = 0
            if dynamic_peek >= 0 then
                dp = peek - dynamic_peek - gap
                dp = ci == 1 and dp or ci == #columns and -dp or 0
            end
            if ci then
                carousel._native.follow(s, tree, ci, mode, dp)
                state.followed_ci = ci
            end
        end }
end

--- Carousel layout declarations for the horizontal strip.
function carousel._clay(s)
    return describe(s, false)
end

--- Native declarations own arrangement of the carousel's clients.
function carousel.arrange() end

function carousel.skip_gap(nclients, t) -- luacheck: no unused args
    return true
end

--- Scroll the viewport by `n` columns worth of width.
-- Positive scrolls right, negative scrolls left.
-- @tparam tag t The tag.
-- @tparam number n Number of viewport-widths to scroll by.
function carousel.scroll_by(t, n)
    local root = get_state(t).publish
    if not t.screen or not root or not root.box then return end
    local viewport = scroll_extent(root.box, root.vertical) - 2 * root.peek
    carousel._native.pan(t.screen, root, n * viewport)
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

--- Return a table containing the column span, viewport dimensions and position,
-- column information and focused client position.
function carousel.get()
    local scr = ascreen.focused()
    local t = scr and scr.selected_tag
    if not t then return end

    local state = get_state(t)
    local focus = capi.client.focus

    local focus_ci = focused_col_idx(state, focus)
    local focus_ri = focused_row_idx(state, focus)

    local root = state.publish
    local box = root and root.box or scr.workarea
    local peek = root and root.peek or 0
    local dp = root and root.dynamic_peek or -1
    local position = root and root.scroll and
        -(root.vertical and root.scroll.y or root.scroll.x) or 0
    local width = 0
    if root and #root.columns > 0 then
        local first, last = root.columns[1].box, root.columns[#root.columns].box
        local axis = root.vertical and "y" or "x"
        if first and last then
            width = last[axis] + scroll_extent(last, root.vertical) - first[axis]
        end
    end
    local info = {
        width = width,
        viewport = { width = box.width, height = box.height, margin = dp >= 0 and dp or peek },
        position = position,
        columns = state.columns,
        focus = {focus_ci, focus_ri},
    }

    return info
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

--- Move the focused client using consume-or-expel semantics.
-- Solo window: consume into the adjacent column (merge with neighbor).
-- Boundary pushes on solo windows are no-ops.
-- Multi-window column: expel the focused window into a new column in
-- the given direction.
-- @tparam number dir Direction: -1 for left, 1 for right.
function carousel.push_window(dir)
    local state, s = get_carousel_context()
    if not state then return end

    local focus = capi.client.focus
    if not focus then return end

    local entry = state.client_to_column[focus]
    if not entry then return end

    local source_col = state.columns[entry.col_idx]

    if #source_col.clients == 1 then
        -- Solo: consume into adjacent column
        local target_ci = entry.col_idx + dir
        if target_ci < 1 or target_ci > #state.columns then return end

        local target_col = state.columns[target_ci]
        table.remove(source_col.clients, 1)
        table.insert(target_col.clients, focus)
        table.remove(state.columns, entry.col_idx)
    else
        -- Multi: expel into new column in given direction
        table.remove(source_col.clients, entry.row_idx)

        local insert_ci
        if dir < 0 then
            insert_ci = entry.col_idx  -- before current
        else
            insert_ci = entry.col_idx + 1  -- after current
        end

        local new_col = {
            clients = { focus },
            width_fraction = source_col.width_fraction,
        }
        table.insert(state.columns, insert_ci, new_col)
    end

    rebuild_index(state)
    get_layout().arrange(s)
end

--- Move the focused client using global directions.
-- Solo window: consume into the column in the given direction (merge with
-- neighbor). Boundary pushes on solo windows are no-ops.
-- Multi-window column: expel the focused window into a new column in
-- the given direction, or shift the focused client's position in the column
-- in the given direction.
-- @tparam string dir Direction: "left", "up", "right", "down".
function carousel.push_window_bydirection(dir)
    local state, s = get_carousel_context()
    if not state then return end

    local focus = capi.client.focus
    if not focus then return end

    local entry = state.client_to_column[focus]
    if not entry then return end

    local source_col = state.columns[entry.col_idx]

    local ch
    if dir == "left" or dir == "up" then ch = -1 end
    if dir == "right" or dir == "down" then ch = 1 end

    if not state.vertical and (dir == "left" or dir == "right") or
            state.vertical and (dir == "up" or dir == "down") then
        if #source_col.clients == 1 then
            -- Solo: consume into adjacent column
            local target_ci = entry.col_idx + ch
            if target_ci < 1 or target_ci > #state.columns then return end

            local target_col = state.columns[target_ci]
            table.remove(source_col.clients, 1)
            table.insert(target_col.clients, focus)
            table.remove(state.columns, entry.col_idx)
        else
            -- Multi: expel into new column in given direction
            table.remove(source_col.clients, entry.row_idx)

            local insert_ci
            if ch < 0 then
                insert_ci = entry.col_idx  -- before current
            else
                insert_ci = entry.col_idx + 1  -- after current
            end

            local new_col = {
                clients = { focus },
                width_fraction = source_col.width_fraction,
            }
            table.insert(state.columns, insert_ci, new_col)
        end
    elseif not state.vertical and (dir == "up" or dir == "down") or
            state.vertical and (dir == "left" or dir == "right") then
        if #source_col.clients > 1 then
            local current_idx
            for _, c in ipairs(source_col.clients) do
                if c == client.focus then current_idx = _ end
            end
            target_idx = current_idx + ch
            if target_idx < 1 or target_idx > #source_col.clients then return end
            table.insert(source_col.clients, target_idx,
                table.remove(source_col.clients, current_idx))
        end
    else return end
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

--- Set the module-level viewport centering mode.
-- Note: `beautiful.carousel_center_mode` takes precedence over this value.
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
-- On release, the viewport centres the nearest column and focuses its first client.
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
            local root = get_state(t).publish
            if not root or not root.scroll then swipe_tag = nil; return end
            swipe_start_offset = vertical and root.scroll.y or root.scroll.x
        end,

        on_update = function(gs)
            if not swipe_tag then return end
            local root = get_state(swipe_tag).publish
            local s = swipe_tag.screen
            if not root or not s then return end
            local x, y = awesome._clay_scroll_get(s, root.id)
            if x == nil then return end
            local delta = vertical and gs.dy or gs.dx
            carousel._native.pan(s, root,
                (vertical and y or x) - swipe_start_offset - delta)
        end,

        on_end = function()
            if not swipe_tag then return end
            local ts = get_state(swipe_tag)
            local root, s = ts.publish, swipe_tag.screen
            if root and s then
                local ci = carousel._native.nearest(s, root)
                if ci then
                    carousel._native.follow(s, root, ci, "always", 0)
                    local c = ts.columns[ci].clients[1]
                    if c then capi.client.focus = c; c:raise() end
                end
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

-- Declare again on focus changes so the describer can request column follow.
capi.client.connect_signal("focus", function(c)
    local s = c.screen
    if not s then return end
    local t = s.selected_tag
    if not t or not is_carousel_layout(s) then return end

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

carousel.vertical.arrange = carousel.arrange
function carousel.vertical._clay(s)
    return describe(s, true)
end

--- Create a gesture binding for vertical carousel swipe panning.
-- @treturn table The awful.gesture binding object.
function carousel.vertical.make_gesture_binding()
    return _make_gesture_binding(true)
end

-- Expose internals for unit testing (not part of the public API).
carousel._test = {
    reconcile = reconcile,
    get_state = get_state,
    rebuild_index = rebuild_index,
}

return carousel

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
