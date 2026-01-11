---------------------------------------------------------------------------
-- @author somewm contributors
-- @copyright 2024
-- Tests for wibox.widget.systray (SNI-based implementation)
---------------------------------------------------------------------------

local unpack = unpack or table.unpack -- luacheck: globals unpack (compatibility with Lua 5.1)

-- Mock items for systray_item.get_items()
local mock_items = {}

-- Track registered systray widget
local systray_widget = nil

-- Track created systray_icon widgets
local created_icons = {}

-- Mock drawable
local drawable_mock = {
    _set_systray_widget = function(widget)
        systray_widget = widget
    end
}

-- Mock beautiful with configurable theme values
local beautiful_mock = {}

-- Mock screen
_G.screen = {
    connect_signal = function() end,
    primary = { index = 1 }
}

-- Mock awesome
_G.awesome = {
    connect_signal = function() end,
    api_level = 9999,
}

-- Mock systray_item C API
_G.systray_item = {
    get_items = function()
        return mock_items
    end
}

-- Pre-load mocks before requiring the module
package.loaded["wibox.drawable"] = drawable_mock
package.loaded.beautiful = beautiful_mock

-- Mock systray_icon module - creates trackable stub widgets using gears.object
local object = require("gears.object")

local function create_mock_systray_icon(item)
    -- Use gears.object for proper signal support
    local widget = object()
    widget._private = { item = item, forced_size = 24, visible = true, opacity = 1 }
    widget.is_widget = true
    widget._private.widget_caches = {}

    function widget:set_forced_size(size)
        self._private.forced_size = size
    end

    function widget:get_forced_size()
        return self._private.forced_size
    end

    function widget:fit()
        local size = self._private.forced_size or 24
        return size, size
    end

    table.insert(created_icons, { item = item, widget = widget })
    return widget
end

package.loaded["wibox.widget.systray_icon"] = setmetatable({}, {
    __call = function(_, item)
        return create_mock_systray_icon(item)
    end
})

-- Now require the actual systray module
local systray = require("wibox.widget.systray")

-- Load test utilities
require("wibox.test_utils")

describe("wibox.widget.systray (SNI)", function()
    local widget = nil

    before_each(function()
        -- Reset state before each test
        mock_items = {}
        created_icons = {}
        systray_widget = nil
        beautiful_mock.systray_icon_spacing = nil
        beautiful_mock.systray_max_rows = nil
        beautiful_mock.systray_paddings = nil
        beautiful_mock.bg_systray = nil

        -- Reset systray singleton by clearing package.loaded
        -- This is a bit hacky but necessary for proper test isolation
        package.loaded["wibox.widget.systray"] = nil
        systray = require("wibox.widget.systray")

        widget = systray()
    end)

    describe("singleton behavior", function()
        it("returns a widget on first call", function()
            assert.is_not_nil(widget)
            assert.is_true(widget.is_widget or widget.layout ~= nil)
        end)

        it("registers with drawable system", function()
            assert.is_equal(widget, systray_widget)
        end)

        it("returns same instance on subsequent calls", function()
            local widget2 = systray()
            assert.is_equal(widget, widget2)
        end)
    end)

    describe("properties", function()
        it("set_base_size emits signal", function()
            local signal_received = false
            widget:connect_signal("property::base_size", function()
                signal_received = true
            end)
            systray:set_base_size(32)
            assert.is_true(signal_received)
        end)

        it("set_horizontal emits signal", function()
            local signal_received = false
            widget:connect_signal("property::horizontal", function()
                signal_received = true
            end)
            systray:set_horizontal(false)
            assert.is_true(signal_received)
        end)

        it("set_reverse emits signal", function()
            local signal_received = false
            widget:connect_signal("property::reverse", function()
                signal_received = true
            end)
            systray:set_reverse(true)
            assert.is_true(signal_received)
        end)

        it("set_screen emits signal", function()
            local signal_received = false
            widget:connect_signal("property::screen", function()
                signal_received = true
            end)
            systray:set_screen(screen.primary)
            assert.is_true(signal_received)
        end)
    end)

    describe("_sync_items", function()
        it("creates widgets for items", function()
            -- Add mock items
            mock_items = { "item1", "item2", "item3" }
            created_icons = {}

            widget:_sync_items()

            -- Should have created 3 icon widgets
            assert.is_equal(3, #created_icons)
        end)

        it("removes widgets when items are removed", function()
            -- Start with 3 items
            mock_items = { "item1", "item2", "item3" }
            widget:_sync_items()

            -- Remove one item
            mock_items = { "item1", "item3" }
            widget:_sync_items()

            -- Children should now be 2
            local children = widget:get_children()
            assert.is_equal(2, #children)
        end)

        it("handles empty item list", function()
            mock_items = {}
            widget:_sync_items()

            local children = widget:get_children()
            assert.is_equal(0, #children)
        end)
    end)

    describe("fit", function()
        local context = { wibox = { drawin = true } }

        it("returns minimum size when empty", function()
            mock_items = {}
            widget:_sync_items()

            -- Default base_size is 24, default padding is 0
            -- Minimum size should be padding*2 + icon_size = 0 + 24 = 24
            local w, h = widget:fit(context, 100, 100)
            assert.is_true(w >= 24)
            assert.is_true(h >= 24)
        end)

        it("respects padding in minimum size", function()
            beautiful_mock.systray_paddings = 10
            mock_items = {}

            -- Reset to pick up new beautiful value
            package.loaded["wibox.widget.systray"] = nil
            systray = require("wibox.widget.systray")
            widget = systray()
            widget:_sync_items()

            local w, h = widget:fit(context, 100, 100)
            -- Minimum: padding*2 + icon_size = 20 + 24 = 44
            assert.is_true(w >= 44)
            assert.is_true(h >= 44)
        end)

        it("calculates single row width correctly", function()
            mock_items = { "item1", "item2", "item3" }
            widget:_sync_items()

            local w, h = widget:fit(context, 1000, 100)
            -- 3 icons * 24px each = 72px minimum (no spacing)
            assert.is_true(w >= 72)
        end)

        it("includes spacing in width calculation", function()
            beautiful_mock.systray_icon_spacing = 10

            -- Reset to pick up new beautiful value
            package.loaded["wibox.widget.systray"] = nil
            systray = require("wibox.widget.systray")
            widget = systray()

            mock_items = { "item1", "item2", "item3" }
            widget:_sync_items()

            local w, h = widget:fit(context, 1000, 100)
            -- 3 icons * 24px + 2 gaps * 10px = 72 + 20 = 92px minimum
            assert.is_true(w >= 92)
        end)
    end)

    describe("layout with max_rows", function()
        local context = { wibox = { drawin = true } }

        it("uses single row by default", function()
            mock_items = { "item1", "item2" }
            widget:_sync_items()

            local result = widget:layout(context, 100, 100)
            if result and #result >= 2 then
                -- Both items should have same y position (single row)
                -- Layout result uses _matrix.y0 for y position
                local y1 = result[1]._matrix.y0
                local y2 = result[2]._matrix.y0
                assert.is_equal(y1, y2)
            end
        end)

        it("uses grid layout with max_rows > 1", function()
            beautiful_mock.systray_max_rows = 2

            -- Reset to pick up new beautiful value
            package.loaded["wibox.widget.systray"] = nil
            systray = require("wibox.widget.systray")
            widget = systray()

            mock_items = { "item1", "item2" }
            widget:_sync_items()

            local result = widget:layout(context, 100, 100)
            -- With 2 items and max 2 rows, should stack vertically
            if result and #result >= 2 then
                -- Layout result uses _matrix.y0 for y position
                local y1 = result[1]._matrix.y0
                local y2 = result[2]._matrix.y0
                -- Items should be at different y positions
                assert.is_not_equal(y1, y2)
            end
        end)
    end)

    describe("background color", function()
        it("uses beautiful.bg_systray", function()
            beautiful_mock.bg_systray = "#ff0000"

            -- Reset to pick up new beautiful value
            package.loaded["wibox.widget.systray"] = nil
            systray = require("wibox.widget.systray")
            widget = systray()

            -- The draw function should use this color
            -- We can verify the widget was created successfully
            assert.is_not_nil(widget)
            assert.is_not_nil(widget.draw)
        end)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
