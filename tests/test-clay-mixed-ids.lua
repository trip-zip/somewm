-- Exercise text-ID readback after floating siblings, popup presentation,
-- frame solve and inspection.
local runner = require("_runner")
local wibox = require("wibox")
local clay = require("wibox.clay")
local base = require("wibox.widget.base")
local s = screen[1]
local bar, popup
local first_ids

local function mixed()
    local w = base.make_widget()
    local font = assert(awesome._clay_font("Sans 12px"))
    clay.describe_widget(w, function()
        return { w = "grow", h = "grow", gap = 4, specs = {
            { float = true, x = 100, y = 0, w = 10, h = 10, bg = {1, 0, 0, 1} },
            { text = "M0a first", font = font, color = {1, 1, 1, 1}, wrap = "none", halign = "left", name = "text" },
            { w = 12, h = 12, bg = {0, 1, 0, 1} },
            { float = true, x = 140, y = 0, w = 10, h = 10, bg = {0, 0, 1, 1} },
            { text = "M0a second", font = font, color = {1, 1, 1, 1}, wrap = "none", halign = "left", name = "text" },
        } }
    end, "m0a.mixed")
    return w
end

local function inspect()
    local rows = {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        -- Declaration rows, not the separate render-command listing.
        if line:match("^    %x+ +text ") then
            local which = line:match('"M0a (%a+)"')
            if which then
                local id = line:match("^    (%x+)")
                local x, y, width, height = line:match("box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
                assert(x, "text ID has no solved box: " .. line)
                rows[which] = { id = id, x = tonumber(x), y = tonumber(y),
                    width = tonumber(width), height = tonumber(height) }
            end
        end
        assert(not line:find("[tree!=scene]", 1, true), line)
    end
    local a, b = rows.first, rows.second
    assert(a and b, "both mixed text siblings must appear in the inspector")
    assert(a.id ~= b.id and a.width > 0 and b.width > 0 and a.height > 0 and b.height > 0, awesome._clay_tree(s))
    assert(a.x == bar.x and a.y == bar.y and b.y == bar.y)
    assert(b.x == a.x + a.width + 12 + 8, "floating siblings changed text flow/readback")
    if first_ids then
        assert(a.id == first_ids[1] and b.id == first_ids[2], "resize changed text identities")
    else
        first_ids = { a.id, b.id }
    end
end

runner.run_steps {
    function()
        -- The popup receives its content size when the frame is solved.
        popup = require("awful").popup { screen = s, visible = true,
            placement = require("awful").placement.top_left,
            widget = wibox.widget.textbox("M0a measurement") }
        return true
    end,
    function(count)
        if not popup._drawable._clay_tree or popup.width <= 1 or popup.height <= 1 then
            assert(count < 30, "popup did not become ready")
            return nil
        end
        assert(popup.width > 1 and popup.height > 1)
        popup.visible = false
        bar = wibox { screen = s, x = s.geometry.x + 10, y = s.geometry.y + 20,
            width = 320, height = 40, visible = true, widget = mixed() }
        awesome._test_redeclare()
        inspect()
        for _ = 1, 3 do
            assert(awesome._test_redeclare() == 0, "unchanged mixed frame did not settle")
            inspect()
        end
        return true
    end,
    function()
        bar.width = 360
        awesome._test_redeclare()
        inspect()
        assert(awesome._test_redeclare() == 0)
        bar.visible = false
        popup.visible = false
        io.stderr:write("[PASS] mixed floating/text IDs survive measurement, frames and inspection\n")
        return true
    end,
}
