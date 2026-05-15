---------------------------------------------------------------------------
--- Shared helpers for layout pixel-position integration tests.
---
--- Used by tests that call `widget:layout(...)` directly and assert against
--- the returned placement objects (test-somewm-layout, test-container-layout,
--- test-titlebar-widget-layout). All three tests previously inlined these.
---------------------------------------------------------------------------

local base = require("wibox.widget.base")

local M = {}

--- Build a widget with a fixed fit size.
function M.stub_widget(w, h)
    local widget = base.make_widget()
    widget.fit = function() return w, h end
    return widget
end

-- Read fields from either the raw rect shape returned by
-- `somewm.layout.solve` (`{widget, x, y, width, height}`) or the
-- `place_widget_at`-wrapped placement shape returned by wibox layouts
-- (`{_widget, _matrix, _width, _height}`).
local function rect_fields(p)
    if p.widget ~= nil then
        return p.widget, p.x, p.y, p.width, p.height
    end
    return p._widget, p._matrix.x0, p._matrix.y0, p._width, p._height
end

--- Linear-search a placement list for the entry belonging to `widget`.
function M.find_placement(placements, widget)
    for _, p in ipairs(placements) do
        local w = rect_fields(p)
        if w == widget then return p end
    end
    return nil
end

--- Assert a placement matches `{ x, y, w, h }` (and optionally `widget`).
function M.expect_placement(label, p, exp)
    assert(p, string.format("[%s] no placement found", label))
    local pw, px, py, pwidth, pheight = rect_fields(p)
    if exp.widget ~= nil then
        assert(pw == exp.widget,
            string.format("[%s] widget mismatch", label))
    end
    assert(px == exp.x,
        string.format("[%s] x: expected %d, got %d", label, exp.x, px))
    assert(py == exp.y,
        string.format("[%s] y: expected %d, got %d", label, exp.y, py))
    assert(pwidth == exp.w,
        string.format("[%s] w: expected %d, got %d", label, exp.w, pwidth))
    assert(pheight == exp.h,
        string.format("[%s] h: expected %d, got %d", label, exp.h, pheight))
end

return M

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
