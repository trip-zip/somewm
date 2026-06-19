---------------------------------------------------------------------------
-- @author Uli Schlachter
-- @copyright 2015 Uli Schlachter and Kazunobu Kuriyama
---------------------------------------------------------------------------

-- Stub awful.button: the widget constructor binds a mouse button, and the real
-- awful.button needs capi backing that is unavailable under busted.
package.loaded["awful.button"] = setmetatable({}, {
    __call = function() return {} end
})

local kb = require("awful.widget.keyboardlayout")

describe("awful.widget.keyboardlayout get_groups_from_group_names", function()
    it("nil", function()
        assert.is_nil(kb.get_groups_from_group_names(nil))
    end)

    local tests = {
        -- possible worst cases
        [""] = {
        },
        ["empty"] = {
        },
        ["empty(basic)"] = {
        },
        -- contrived cases for robustness test
        ["pc()+de+jp+group()"] = {
            { file = "de", group_idx = 1 },
            { file = "jp", group_idx = 1 }
        },
        ["us(altgr-intl)"] = {
            { file = "us", group_idx = 1, section = "altgr-intl" }
        },
        -- possible eight variations of a single term
        ["de"] = {
            { file = "de", group_idx = 1 }
        },
        ["de:2" ] = {
            { file = "de", group_idx = 2 }
        },
        ["de(nodeadkeys)"] = {
            { file = "de", group_idx = 1, section = "nodeadkeys" }
        },
        ["de(nodeadkeys):2"] = {
            { file = "de", group_idx = 2, section = "nodeadkeys" }
        },
        ["macintosh_vndr/de"] = {
            { file = "de", group_idx = 1, vendor = "macintosh_vndr" }
        },
        ["macintosh_vndr/de:2"] = {
            { file = "de", group_idx = 2, vendor = "macintosh_vndr" }
        },
        ["macintosh_vndr/de(nodeadkeys)"] = {
            { file = "de", group_idx = 1, vendor = "macintosh_vndr", section = "nodeadkeys" }
        },
        ["macintosh_vndr/de(nodeadkeys):2"] = {
            { file = "de", group_idx = 2, vendor = "macintosh_vndr", section = "nodeadkeys" }
        },
        -- multiple terms
        ["pc+de"] = {
            { file = "de", group_idx = 1 }
        },
        ["pc+us+inet(evdev)+terminate(ctrl_alt_bksp)"] = {
            { file = "us", group_idx = 1 }
        },
        ["pc(pc105)+us+group(caps_toggle)+group(ctrl_ac)"] = {
            { file = "us", group_idx = 1 }
        },
        ["pc+us(intl)+inet(evdev)+group(win_switch)"] = {
            { file = "us", group_idx = 1, section = "intl" }
        },

        ["macintosh_vndr/apple(alukbd)+macintosh_vndr/jp(usmac)"] = {
            { file = "jp", group_idx = 1, vendor = "macintosh_vndr", section = "usmac" },
        },
        -- multiple layouts
        ["pc+jp+us:2+inet(evdev)+capslock(hyper)"] = {
            { file = "jp", group_idx = 1 },
            { file = "us", group_idx = 2 }
        },
        ["pc+us+ru:2+de:3+ba:4+inet"] = {
            { file = "us", group_idx = 1 },
            { file = "ru", group_idx = 2 },
            { file = "de", group_idx = 3 },
            { file = "ba", group_idx = 4 },
        },
        ["macintosh_vndr/apple(alukbd)+macintosh_vndr/jp(usmac)+macintosh_vndr/jp(mac):2+group(shifts_toggle)"] = {
            { file = "jp", group_idx = 1, vendor = "macintosh_vndr", section = "usmac" },
            { file = "jp", group_idx = 2, vendor = "macintosh_vndr", section = "mac" },
        },
    }

    for arg, expected in pairs(tests) do
        it(arg, function()
            assert.is.same(expected, kb.get_groups_from_group_names(arg))
        end)
    end
end)

describe("awful.widget.keyboardlayout next_layout/set_layout", function()
    -- Build a fresh widget backed by a stubbed 2-layout keymap (us, cz).
    local function make_widget()
        awesome.xkb_get_group_names  = function() return "pc+us+cz:2+inet(evdev)" end
        awesome.xkb_get_layout_group = function() return 0 end
        awesome.connect_signal       = function() end
        local set_calls = {}
        awesome.xkb_set_layout_group = function(n) set_calls[#set_calls + 1] = n end
        return kb.new(), set_calls
    end

    it("parses two layouts from the group names", function()
        local w = make_widget()
        assert.is.equal(2, #w._layout)
    end)

    it("advances to the next group", function()
        local w, set_calls = make_widget()
        w._current = 0
        w.next_layout()
        assert.is.same({ 1 }, set_calls)
    end)

    it("wraps from the last group back to the first", function()
        -- Regression: the wrap-around once produced an out-of-range group.
        local w, set_calls = make_widget()
        w._current = 1            -- last group of a 2-layout keymap (0-based)
        w.next_layout()
        assert.is.same({ 0 }, set_calls)
    end)

    it("rejects out-of-range group numbers", function()
        local w = make_widget()
        assert.has_error(function() w.set_layout(#w._layout) end)
        assert.has_error(function() w.set_layout(-1) end)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
