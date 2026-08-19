---------------------------------------------------------------------------
-- @author somewm contributors
-- @copyright 2026
-- Tests for wibox.widget.systray_icon sizing
---------------------------------------------------------------------------

local systray_icon = require("wibox.widget.systray_icon")

-- Build the widget state :fit reads, without the constructor: it lazily
-- requires awful.tooltip, which needs the whole capi drawin chain.
local function icon(private)
    return setmetatable({ _private = private }, { __index = systray_icon })
end

-- A stand-in for the C systray_item, carrying the native pixmap dimensions a
-- StatusNotifierItem reported over D-Bus.
local function item(icon_width, icon_height)
    return { icon_width = icon_width, icon_height = icon_height }
end

describe("wibox.widget.systray_icon", function()
    describe("fit", function()
        local context = {}

        it("uses forced_size when the item has no icon", function()
            local widget = icon { forced_size = 22 }

            assert.is.same({22, 22}, {widget:fit(context, 1000, 1000)})
        end)

        it("ignores an oversized source pixmap", function()
            local widget = icon { forced_size = 22, item = item(256, 256) }

            assert.is.same({22, 22}, {widget:fit(context, 1000, 1000)})
        end)

        it("ignores a source pixmap smaller than forced_size", function()
            local widget = icon { forced_size = 32, item = item(16, 16) }

            assert.is.same({32, 32}, {widget:fit(context, 1000, 1000)})
        end)

        it("stays square for a non-square source pixmap", function()
            local widget = icon { forced_size = 24, item = item(128, 32) }

            assert.is.same({24, 24}, {widget:fit(context, 1000, 1000)})
        end)

        it("respects forced_width and forced_height", function()
            local widget = icon {
                forced_size = 24, forced_width = 40, forced_height = 12,
                item = item(256, 256),
            }

            assert.is.same({40, 12}, {widget:fit(context, 1000, 1000)})
        end)

        it("never exceeds the available space", function()
            local widget = icon { forced_size = 24, item = item(256, 256) }

            assert.is.same({24, 10}, {widget:fit(context, 1000, 10)})
        end)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
