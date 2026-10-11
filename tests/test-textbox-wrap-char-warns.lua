---------------------------------------------------------------------------
-- Test: Clay wraps every textbox at words; wrap = "char" warns once
--
-- A default textbox (wrap "word_char") logs nothing. Two textboxes set to
-- "char" are text elements in the dump and log one warning naming wrap.
--
-- Run: make test-one TEST=tests/test-textbox-wrap-char-warns.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")

local s = screen[1]
local bar, column

local function log_text()
    io.stderr:flush()
    local f = assert(io.open(assert(os.getenv("SOMEWM_TEST_LOG"))))
    local text = f:read("*a")
    f:close()
    return text
end

local function wrap_warnings()
    local _, n = log_text():gsub("wibox%.clay: [^\n]* wrap [^\n]*", "")
    return n
end

-- The dump line of a text element, or nil before a frame shows it.
local function text_line(text)
    local dump = awesome._clay_tree(s)
    return dump:match("[^\n]* text \"" .. text .. "\" [^\n]*"), dump
end

runner.run_steps {
    function()
        column = wibox.layout.fixed.vertical()
        column:add(wibox.widget.textbox("wrapdefaultprobe"))
        bar = wibox { screen = s, x = 0, y = 0, width = 300, height = 80,
            visible = true, bg = "#101010", widget = column }
        return true
    end,
    function(count)
        if not text_line("wrapdefaultprobe") then
            assert(count < 50, "the default textbox never reached the dump")
            return nil
        end
        assert(wrap_warnings() == 0, "a default textbox warned about wrap")
        for _, text in ipairs { "wrapcharprobe", "wrapcharsecond" } do
            column:add(wibox.widget { widget = wibox.widget.textbox, text = text, wrap = "char" })
        end
        return true
    end,
    function(count)
        local first = text_line("wrapcharprobe")
        local second, dump = text_line("wrapcharsecond")
        if not first or not second then
            assert(count < 50, "the char textboxes never reached the dump")
            return nil
        end
        local _, warnings = log_text():gsub(
            'wibox%.clay: [^\n]* wrap is "char" and wraps at words', "")
        assert(warnings == 1, "expected one wrap warning, got " .. warnings)
        assert(wrap_warnings() == 1, "expected no other wrap warning")
        io.stderr:write("matched:" .. first .. "\nmatched:" .. second .. "\n" .. dump .. "\n")
        bar.visible = false
        return true
    end,
}
