---------------------------------------------------------------------------
-- Test: a textbox converts to a Clay text element
--
-- A converted textbox is a content descriptor: Clay measures it through the
-- renderer's measure callback and the renderer rasters it with pangocairo,
-- so the widget draws nothing itself. Plain text converts, and so does
-- Pango markup that amounts to one run of one font and one color, which is
-- what the taglist and tasklist labels are; richer markup uses the first
-- run (third_party/clay.h:374-398). An empty textbox draws nothing and takes
-- nothing, so it has no element, and stays wired for a later value. A text
-- change is a tree change.
--
-- Run: make test-one TEST=tests/test-clay-textbox.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")

local s = screen[1]
local BX, BY, BW, BH = 0, 0, 400, 24
local BAR_BG = "#101010"
local cap = capture.new(s, BX, BY, BW, BH)
local bar, plain, span, bold, empty

-- The tree nodes of the bar's dump block.
local function nodes()
    local d = bar.drawin
    local want = string.format("  drawin screen %d %dx%d+%d+%d ", s.index,
        d.width, d.height, d.x, d.y)
    local head, out = nil, {}

    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if head then
            local indent, class = line:match("^    %x+ ( *)([%w_.-]+)")
            if not indent then
                break
            end
            local x, y, w, h = line:match("box (%d+),(%d+) (%d+)x(%d+)")
            out[#out + 1] = { depth = #indent / 2, class = class,
                image = line:find(" image ", 1, true) ~= nil, line = line,
                box = x and { x = tonumber(x), y = tonumber(y),
                    width = tonumber(w), height = tonumber(h) } }
        elseif line:sub(1, #want) == want then
            head = line
        end
    end
    return head, out
end

-- Each original textbox binds to its actual sizing container. Its glyph is
-- a native TEXT child.
local function textboxes(list)
    local out = {}
    for _, widget in ipairs { plain, span, bold } do
        local binding = assert(bar._drawable._clay_wired[widget])[1]
        local element = assert(binding.element)
        local found, glyph
        for index, node in ipairs(list) do
            local box = node.box
            if box and box.x == element.box.x and box.y == element.box.y
                    and box.width == element.box.width and box.height == element.box.height
                    and node.class == (element.text and "text" or "wibox.widget.textbox") then
                assert(not found, "ambiguous textbox element in native dump")
                found = node
                glyph = element.text and node or list[index + 1]
                if glyph and (glyph.class ~= "text" or (not element.text and glyph.depth ~= node.depth + 1)) then glyph = nil end
            end
        end
        assert(found, "original textbox has no matching real solved element")
        out[#out + 1] = {node = found, text = glyph, element = element}
    end
    return out
end

-- Whether any pixel inside a box differs from the bar's background.
local function inked(shot, box)
    for y = box.y + 1, box.y + box.height - 2 do
        for x = box.x + 1, box.x + box.width - 2 do
            local r, g, b = cap:pixel(shot, x, y)
            if r ~= 0x10 or g ~= 0x10 or b ~= 0x10 then
                return true
            end
        end
    end
    return false
end

local steps = {
    function(count)
        if count == 1 then
            plain = wibox.widget.textbox("Hello world")
            plain.font = "Sans 10"
            span = wibox.widget.textbox(
                "<span font_desc='Sans 10' color='#ff0000'>Red &amp; plain</span>")
            bold = wibox.widget.textbox("<b>Bold</b> and not")
            -- The prompt's textbox: empty, ellipsized at the start.
            empty = wibox.widget.textbox()
            empty:set_ellipsize("start")
            bar = wibox {
                x = BX, y = BY, width = BW, height = BH, screen = s,
                bg = BAR_BG, fg = "#ffffff", visible = true,
            }
            bar:setup {
                layout = wibox.layout.fixed.horizontal,
                spacing = 10,
                plain, span, bold, empty,
            }
            return nil
        end

        local head, list = nodes()

        if not head or (head:find("converted", 1, true) and #list == 0) then
            assert(count < 20, "the bar never reached the dump")
            return nil
        end
        assert(head:find("converted", 1, true), "the bar did not convert: " .. head)

        local tb = textboxes(list)

        assert(#tb == 3, "expected three textboxes, got " .. #tb)
        assert(not tb[1].node.image and tb[1].text,
            "plain text did not become a text element: " .. tb[1].node.line)
        assert(tb[1].text.line:find('"Hello world"', 1, true),
            "the text element does not carry the text: " .. tb[1].text.line)
        assert(not tb[2].node.image and tb[2].text,
            "a one-run markup did not become a text element: " .. tb[2].node.line)
        assert(tb[2].text.line:find('"Red & plain"', 1, true),
            "the markup's text is not unescaped: " .. tb[2].text.line)
        assert(#awesome._test_widget_boxes(bar.drawin) == 4, "the converted widgets do not all have boxes")
        assert(tb[3].text and tb[3].text.line:find('"Bold and not"', 1, true),
            "the multi-run markup is not one text element: " .. tb[3].node.line)
        -- The empty textbox has no element of its own, and stays wired so a
        -- value declares one.
        local wired = assert(bar._drawable._clay_wired[empty])[1]
        assert(wired and not wired.element, "an empty textbox still has an element")
        -- Clay sized the textboxes: fit along, the whole bar across.
        assert(not tb[1].element.text and (tb[1].element.w or "fit") == "fit"
            and tb[1].element.h == "grow",
            "the textbox is not sized by Clay: " .. tb[1].node.line)
        assert(tb[1].node.box.width > 20 and tb[1].node.box.height == BH,
            "the textbox has no text-sized box: " .. tb[1].node.line)
        io.stderr:write("[PASS] textboxes convert to text elements\n")
        return true
    end,

    -- The renderer draws the text: ink in each textbox, red in the span.
    function(count)
        local _, list = nodes()
        local tb = textboxes(list)
        local shot = cap:shot()

        if not (inked(shot, tb[1].node.box) and inked(shot, tb[2].node.box)) then
            assert(count < 20, "no text was drawn")
            return nil
        end
        local red = false
        for y = 2, BH - 3 do
            for x = tb[2].node.box.x + 1, tb[2].node.box.x + tb[2].node.box.width - 2 do
                local r, g, b = cap:pixel(shot, x, y)
                if r > 0xc0 and g < 0x40 and b < 0x40 then
                    red = true
                end
            end
        end
        assert(red, "the span's color did not reach the renderer")
        io.stderr:write("[PASS] the renderer draws the text\n")
        return true
    end,

    -- A text change is a tree change: the box follows the new text.
    function(count)
        if count == 1 then
            plain.text = "Hello wider world"
            return nil
        end

        local _, list = nodes()
        local tb = textboxes(list)

        if not (tb[1].text and tb[1].text.line:find('"Hello wider world"', 1, true)) then
            assert(count < 20, "the new text never reached the tree")
            return nil
        end
        assert(tb[2].node.box.x > tb[1].node.box.x + 60,
            "the next textbox did not move for the wider text")
        io.stderr:write("[PASS] a text change resolves\n")
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
