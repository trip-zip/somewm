---------------------------------------------------------------------------
-- The magnifier layout. The focused client floats centered at
-- `sqrt(master_width_factor)` of the workarea; remaining clients tile
-- behind it as a full-area column.
--
-- magnifier stays a bespoke arrange(p) rather than a merge-capable descriptor
-- because it positions clients by focus, not by the tiled-client set:
-- need_focus_update re-arranges on focus change, and mouse_resize_handler
-- drives master_width_factor from a center-anchored drag. It writes the OUTER
-- box per client to p.geometries; compose_screen reflects those as
-- root-attached leaves in the one screen solve, so magnifier's clients flow
-- through the single C apply path and the assertion sees them. It is a
-- documented bespoke leaf, allow-listed as a descriptor-less layout.
---------------------------------------------------------------------------

local ipairs = ipairs
local math   = math
local capi   = {
    client       = client,
    screen       = screen,
    mouse        = mouse,
    mousegrabber = mousegrabber,
}

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

        -- Background: the non-focused clients, ordered as the legacy layout did
        -- (after focus first, then before) so the stacking order on tag refocus
        -- is preserved. They tile as an equal vertical column filling wa.
        local bg, fidx = {}, nil
        for k, c in ipairs(cls) do
            if c == focus then fidx = k; break end
        end
        -- The focused client may not be in the tiled set (client.tiled excludes
        -- fullscreen / maximized clients, which keep floating == false and so
        -- pass the guard above): fall back to magnifying the first tiled client
        -- rather than indexing with a nil fidx.
        if not fidx then focus, fidx = cls[1], 1 end
        for k = fidx + 1, #cls do bg[#bg + 1] = cls[k] end
        for k = 1, fidx - 1 do bg[#bg + 1] = cls[k] end

        local n = #bg
        if n > 0 then
            local slot = math.floor((wa.height - (n - 1) * gap) / n)
            for i, c in ipairs(bg) do
                -- OUTER box = the slot grown by gap (the legacy convention: the
                -- slot already includes the border region). reflect_geometries
                -- subtracts the gap and C subtracts the border, so the client
                -- surface is the slot minus its border. No border term here,
                -- unlike carousel, which starts from an applied surface and adds
                -- the border back so the round-trip preserves it.
                p.geometries[c] = {
                    x      = wa.x - gap,
                    y      = wa.y + (i - 1) * (slot + gap) - gap,
                    width  = wa.width + 2 * gap,
                    height = slot + 2 * gap,
                }
            end
        end

        -- Overlay: the focused client centered over the background. With a
        -- single client it fills the workarea (sq = 1); with more it shrinks to
        -- sqrt(mwfact). It overlaps the background, so it must stack above (the
        -- focus path raises it). Same OUTER-box convention as the background.
        local sq = (#cls > 1) and math.sqrt(mwfact) or 1
        local fw = math.floor(wa.width  * sq)
        local fh = math.floor(wa.height * sq)
        local ox = math.floor((wa.width  - fw) / 2)
        local oy = math.floor((wa.height - fh) / 2)
        p.geometries[focus] = {
            x      = wa.x + ox - gap,
            y      = wa.y + oy - gap,
            width  = fw + 2 * gap,
            height = fh + 2 * gap,
        }
    end

    clay.magnifier = {
        name                 = "clay.magnifier",
        arrange              = arrange,
        need_focus_update    = true,
        mouse_resize_handler = mouse_resize_handler,
    }
end

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
