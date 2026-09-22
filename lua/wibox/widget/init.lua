---------------------------------------------------------------------------
--- Utility function for working with widgets.
--
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @module wibox.widget
---------------------------------------------------------------------------

local widget = {
    base = require("wibox.widget.base");
    textbox = require("wibox.widget.textbox");
    imagebox = require("wibox.widget.imagebox");
    systray = require("wibox.widget.systray");
    systray_icon = require("wibox.widget.systray_icon");
    textclock = require("wibox.widget.textclock");
    progressbar = require("wibox.widget.progressbar");
    graph = require("wibox.widget.graph");
    checkbox = require("wibox.widget.checkbox");
    piechart = require("wibox.widget.piechart");
    slider = require("wibox.widget.slider");
    calendar = require("wibox.widget.calendar");
    separator = require("wibox.widget.separator");
}

setmetatable(widget, {
    __call = function(_, args)
        return widget.base.make_widget_declarative(args)
    end
})

return widget

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
