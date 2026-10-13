---------------------------------------------------------------------------
-- @author Uli Schlachter
-- @copyright 2015 Uli Schlachter
---------------------------------------------------------------------------

local textbox = require("wibox.widget.textbox")

local test_dpi_value = 192
_G.screen = {
    { geometry = { x = 0, y = 0, width = 1920, height = 1080 }, index = 1, dpi=test_dpi_value },
}
local beautiful = require("beautiful")
local xresources = require("beautiful.xresources")
beautiful.font = 'Monospace 10'
xresources.get_dpi = function(_) return test_dpi_value end
package.loaded["beautiful"] = beautiful
package.loaded["beautiful.xresources"] = xresources

describe("wibox.widget.textbox", function()
    local widget
    before_each(function()
        widget = textbox()
    end)

    describe("failed font changes", function()
        local get_font
        before_each(function()
            get_font = beautiful.get_font
        end)
        after_each(function()
            beautiful.get_font = get_font
        end)

        for _, failure in ipairs({ "lookup", "description" }) do
            it("preserves the applied font after a " .. failure .. " failure", function()
                local original = widget:get_font()
                local attempts = 0
                beautiful.get_font = function(name)
                    if name == "bad font" then
                        attempts = attempts + 1
                        if failure == "lookup" then
                            error("font lookup failed")
                        end
                        return false
                    end
                    return get_font(name)
                end

                assert.has_error(function() widget:set_font("bad font") end)
                assert.equals(original, widget:get_font())
                assert.has_error(function() widget:set_font("bad font") end)
                assert.equals(2, attempts)
                widget:set_font("Monospace 20")
                assert.equals("Monospace 20", widget:get_font())
                assert.has_error(function() widget:set_font("bad font") end)
                assert.equals(3, attempts)
                assert.equals("Monospace 20", widget:get_font())
            end)
        end
    end)

    describe("emitting signals", function()
        local redraw_needed, layout_changed
        before_each(function()
            widget:connect_signal("widget::redraw_needed", function()
                redraw_needed = redraw_needed + 1
            end)
            widget:connect_signal("widget::layout_changed", function()
                layout_changed = layout_changed + 1
            end)
            redraw_needed, layout_changed = 0, 0
        end)

        it("text and markup", function()
            assert.is.equal(0, redraw_needed)
            assert.is.equal(0, layout_changed)

            widget:set_text("text")
            assert.is.equal(1, redraw_needed)
            assert.is.equal(1, layout_changed)

            widget:set_text("text")
            assert.is.equal(1, redraw_needed)
            assert.is.equal(1, layout_changed)

            widget:set_text("<b>text</b>")
            assert.is.equal(2, redraw_needed)
            assert.is.equal(2, layout_changed)

            widget:set_markup("<b>text</b>")
            assert.is.equal(3, redraw_needed)
            assert.is.equal(3, layout_changed)

            widget:set_markup("<b>text</b>")
            assert.is.equal(3, redraw_needed)
            assert.is.equal(3, layout_changed)
        end)

        it("set_ellipsize", function()
            assert.is.equal(0, redraw_needed)
            assert.is.equal(0, layout_changed)

            widget:set_ellipsize("end")
            assert.is.equal(0, redraw_needed)
            assert.is.equal(0, layout_changed)

            widget:set_ellipsize("none")
            assert.is.equal(1, redraw_needed)
            assert.is.equal(1, layout_changed)
        end)

        it("set_wrap", function()
            assert.is.equal(0, redraw_needed)
            assert.is.equal(0, layout_changed)

            widget:set_wrap("word_char")
            assert.is.equal(0, redraw_needed)
            assert.is.equal(0, layout_changed)

            widget:set_wrap("char")
            assert.is.equal(1, redraw_needed)
            assert.is.equal(1, layout_changed)
        end)

        it("set_valign", function()
            assert.is.equal(0, redraw_needed)
            assert.is.equal(0, layout_changed)

            widget:set_valign("center")
            assert.is.equal(0, redraw_needed)
            assert.is.equal(0, layout_changed)

            widget:set_valign("top")
            assert.is.equal(1, redraw_needed)
            assert.is.equal(1, layout_changed)
        end)

        it("set_halign", function()
            assert.is.equal(0, redraw_needed)
            assert.is.equal(0, layout_changed)

            widget:set_halign("left")
            assert.is.equal(0, redraw_needed)
            assert.is.equal(0, layout_changed)

            widget:set_halign("right")
            assert.is.equal(1, redraw_needed)
            assert.is.equal(1, layout_changed)
        end)

        it("set_font", function()
            assert.is.equal(0, redraw_needed)
            assert.is.equal(0, layout_changed)

            widget:set_font("foo")
            assert.is.equal(1, redraw_needed)
            assert.is.equal(1, layout_changed)

            widget:set_font("bar")
            assert.is.equal(2, redraw_needed)
            assert.is.equal(2, layout_changed)
        end)
    end)

    describe("auxiliary", function()

        it("can compute text geometry w/default font", function()
            local text = "<b><i>test</i></b>"
            local s = 1
            local pango_geometry = textbox.get_markup_geometry(text, s)
            local actual_textbox_width, actual_textbox_height = textbox(text):get_preferred_size(s)
            assert.is.equal(pango_geometry.width, actual_textbox_width)
            assert.is.equal(pango_geometry.height, actual_textbox_height)
        end)

        it("can compute text geometry w/hardcoded font", function()
            local text = "<span font='Monospace 16'><b><i>test</i></b></span>"
            local s = 1
            local pango_geometry = textbox.get_markup_geometry(text, s)
            local actual_textbox_width, actual_textbox_height = textbox(text):get_preferred_size(s)
            assert.is.equal(pango_geometry.width, actual_textbox_width)
            assert.is.equal(pango_geometry.height, actual_textbox_height)
        end)

    end)

end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
