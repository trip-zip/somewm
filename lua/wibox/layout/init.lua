---------------------------------------------------------------------------
--- Collection of layouts that can be used in widget boxes.
--
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @classmod wibox.layout
---------------------------------------------------------------------------
local base = require("wibox.widget.base")

return setmetatable({
    fixed = require("wibox.layout.fixed");
    align = require("wibox.layout.align");
    flex = require("wibox.layout.flex");
    manual = require("wibox.layout.manual");
    ratio = require("wibox.layout.ratio");
    stack = require("wibox.layout.stack");
    grid = require("wibox.layout.grid");
    overflow = require("wibox.layout.overflow");
}, {__call = function(_, args) return base.make_widget_declarative(args) end})

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
