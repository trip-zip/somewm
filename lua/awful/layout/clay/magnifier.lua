---------------------------------------------------------------------------
-- The magnifier layout. The focused client floats centered at
-- `sqrt(master_width_factor)` of the workarea; remaining clients tile
-- behind it as a full-area column.
--
-- Two `layout.solve` passes per arrange because the focused client
-- visually overlays the others: Clay's flexbox model can't express a
-- single tree where a child's bounds extend beyond a sibling's. Pass 1
-- writes geometries for the background column, pass 2 writes the
-- centered focused client. Each client receives exactly one geometry
-- assignment so the two passes don't conflict.
--
-- This preset deliberately bypasses the Clay descriptor shape used by
-- tile/fair/max/corner/spiral. The descriptor pipeline (subtree +
-- tag_suit_from_descriptor) produces ONE tree per arrange; magnifier
-- needs TWO. Until Clay (or a successor engine) gains an overlap
-- primitive, the bespoke arrange function stays. This is not a TODO,
-- it is a documented exception to "Clay everywhere" (see DEVIATIONS).
---------------------------------------------------------------------------

local ipairs = ipairs
local math   = math
local capi   = {
    client       = client,
    screen       = screen,
    mouse        = mouse,
    mousegrabber = mousegrabber,
}
local layout = require("somewm.layout")

-- Interactive resize for magnifier: dragging away from the workarea
-- center shrinks the focused (magnified) client; dragging toward the
-- center grows it. Implemented as a continuous mwfact update rather
-- than corner-anchored resize because the magnified client is centered.
local function mouse_resize_handler(c, corner, x, y)
    capi.mouse.coords({ x = x, y = y })

    local wa = c.screen.workarea
    local center_x = wa.x + wa.width  / 2
    local center_y = wa.y + wa.height / 2
    local maxdist_pow = (wa.width ^ 2 + wa.height ^ 2) / 4

    local prev_coords = {}
    capi.mousegrabber.run(function(position)
        if not c.valid then return false end

        for _, v in ipairs(position.buttons) do
            if v then
                prev_coords = { x = position.x, y = position.y }
                local dx = center_x - position.x
                local dy = center_y - position.y
                local dist = dx ^ 2 + dy ^ 2
                local mwfact = dist / maxdist_pow
                c.screen.selected_tag.master_width_factor =
                    math.min(math.max(0.01, mwfact), 0.99)
                return true
            end
        end
        return prev_coords.x == position.x and prev_coords.y == position.y
    end, corner .. "_corner")
end

return function(clay)
    local function get_screen(s)
        return s and capi.screen[s]
    end

    local function arrange(p)
        local cls = p.clients
        if #cls == 0 then return end

        local t      = p.tag or capi.screen[p.screen].selected_tag
        local mwfact = t.master_width_factor
        local gap    = p.useless_gap or 0
        local focus  = p.focus or capi.client.focus

        if focus and focus.screen ~= get_screen(p.screen) then
            focus = nil
        end
        if not focus or focus.floating then
            focus = cls[1]
        end
        if not focus then return end

        local wa = p.workarea

        local fidx
        for k, c in ipairs(cls) do
            if c == focus then fidx = k; break end
        end

        -- Pass 1: tile non-focused clients to fill the workarea. Order
        -- matches the legacy code (clients after focus first, then before)
        -- so the visible stacking order on tag refocus is preserved.
        if #cls > 1 then
            local children = {}
            for k = fidx + 1, #cls do
                children[#children + 1] = layout.client(cls[k], { grow = true })
            end
            for k = 1, fidx - 1 do
                children[#children + 1] = layout.client(cls[k], { grow = true })
            end

            layout.solve {
                screen   = p.screen,
                source   = "magnifier",
                width    = wa.width, height = wa.height,
                offset_x = wa.x,     offset_y = wa.y,
                root     = layout.column { gap = gap, children },
            }
        end

        -- Pass 2: focused client centered. With a single client, Clay
        -- assigns it the full workarea (size_pct = 100); with more, the
        -- focused client shrinks to sqrt(mwfact) and overlays the others.
        local size_pct = (#cls > 1) and (math.sqrt(mwfact) * 100) or 100
        layout.solve {
            screen   = p.screen,
            source   = "magnifier",
            width    = wa.width, height = wa.height,
            offset_x = wa.x,     offset_y = wa.y,
            root     = layout.row {
                grow  = true,
                align = { x = "center", y = "center" },
                layout.client(focus, {
                    width  = layout.percent(size_pct),
                    height = layout.percent(size_pct),
                }),
            },
        }

        p._clay_managed = true
    end

    clay.magnifier = {
        name                 = "clay.magnifier",
        arrange              = arrange,
        need_focus_update    = true,
        mouse_resize_handler = mouse_resize_handler,
    }
end

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
