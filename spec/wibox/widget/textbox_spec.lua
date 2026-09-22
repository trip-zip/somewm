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

-- The helper changes offers repeatedly without changing text semantics. These
-- checks cover the cache's real invalidators and declaration ownership.
describe("textbox Clay text inputs", function()
    local old_font, calls
    before_each(function()
        old_font = awesome._clay_font
        calls = 0
        awesome._clay_font = function(description)
            calls = calls + 1
            return description
        end
    end)
    after_each(function() awesome._clay_font = old_font end)
    local function describe_text(w, dpi, fg)
        return textbox._clay.describe(w, fg or '#ffffff', {context={dpi=dpi or 96}})
    end
    it("reuses metadata across offers, but refreshes content, font and DPI", function()
        local w = textbox('first');w.font='monospace 10'
        local first = describe_text(w).specs[1]
        assert.equals('first', first.text)
        assert.equals(first.font, describe_text(w).specs[1].font)
        assert.equals(1, calls)
        w.text='second'
        assert.equals('second', describe_text(w).specs[1].text)
        assert.equals(1, calls)
        local sibling=textbox('third');sibling.font='monospace 10'
        local description=w._private.layout:get_font_description():to_string()
        assert.equals(first.font,describe_text(sibling).specs[1].font)
        assert.equals(1,calls)
        assert.equals(description,w._private.layout:get_font_description():to_string())
        w.font='monospace 16'
        local larger=describe_text(w).specs[1].font
        assert.is_not.equals(first.font, larger)
        assert.is_not.equals(larger, describe_text(w,192).specs[1].font)
        w.text=''
        assert.is_nil(describe_text(w).specs)
        w.text='restored'
        assert.equals('restored',describe_text(w).specs[1].text)
    end)
    it("keeps foreground and opacity mutations outside cached markup inputs", function()
        local w=textbox('<span foreground="#ff0000">red</span>')
        local first=describe_text(w).specs[1]
        first.color[4]=0.25
        local second=describe_text(w).specs[1]
        assert.same({1,0,0,1},second.color)
        assert.equals(1,calls)
        w.text='plain'
        assert.same({0,1,0,1},describe_text(w,96,'#00ff00').specs[1].color)
        assert.same({0,0,1,1},describe_text(w,96,'#0000ff').specs[1].color)
        w.halign='right';w.valign='top';w.ellipsize='none'
        local n=describe_text(w)
        assert.same({x='right',y='top'},n.align)
        assert.is_false(n.specs[1].ellipsize)
    end)
end)
