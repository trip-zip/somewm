---------------------------------------------------------------------------
-- @author somewm contributors
-- @copyright 2024
-- Tests for wibox.widget.systray (SNI-based implementation)
---------------------------------------------------------------------------

local unpack = unpack or table.unpack -- luacheck: globals unpack (compatibility with Lua 5.1)

-- Mock items for systray_item.get_items()
local mock_items = {}

-- Track created systray_icon widgets
local created_icons = {}

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
}

-- Mock systray_item C API
_G.systray_item = {
    get_items = function()
        return mock_items
    end
}

-- Pre-load mocks before requiring the module
package.loaded.beautiful = beautiful_mock

-- Mock systray_icon module - creates trackable stub widgets using gears.object
local object = require("gears.object")

local function create_mock_systray_icon(item)
    -- Use gears.object for proper signal support
    local widget = object()
    widget._private = { item = item, forced_size = 24, visible = true, opacity = 1 }
    widget.is_widget = true

    function widget:set_forced_size(size)
        self._private.forced_size = size
    end

    function widget:get_forced_size()
        return self._private.forced_size
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


    describe("clay properties", function()
        it("draws multiple rows as one", function()
            beautiful_mock.systray_max_rows = 2
            local warning = stub(require("gears.debug"), "print_warning")
            assert.is_not_nil(widget._clay.describe(widget))
            assert.stub(warning).was_called(1)
            warning:revert()
        end)

        it("rounds padding", function()
            beautiful_mock.systray_paddings = 2.5
            assert.is_same({ 3, 3, 3, 3 }, widget._clay.describe(widget).pad)
        end)

        it("omits a gradient background", function()
            beautiful_mock.bg_systray = "linear:0,0:10,0:0,#000000:1,#ffffff"
            local warning = stub(require("gears.debug"), "print_warning")
            assert.is_nil(widget._clay.describe(widget).bg)
            assert.stub(warning).was_called(1)
            warning:revert()
        end)
    end)

    describe("background color", function()
        it("uses beautiful.bg_systray", function()
            beautiful_mock.bg_systray = "#ff0000"

            -- Reset to pick up new beautiful value
            package.loaded["wibox.widget.systray"] = nil
            systray = require("wibox.widget.systray")
            widget = systray()

            -- The describer carries the configured background color.
            assert.is_not_nil(widget)
            assert.is_same({ 1, 0, 0, 1 }, widget._clay.describe(widget).bg)
        end)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
