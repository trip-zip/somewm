local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")

local s = screen[1]
local cap = capture.new(s, 0, 0, 400, 64)
local bar, label, plain_box, plain_shot
local failures = {}
local function check(ok, message)
    if not ok then failures[#failures + 1] = message end
    io.stderr:write((ok and "[PASS] " or "[FAIL] ") .. message .. "\n")
end
local function log()
    local file = assert(io.open(os.getenv("SOMEWM_TEST_LOG")))
    local text = file:read("*a")
    file:close()
    return text
end
-- The bar's nth TEXT command; Clay emits one per line.
local function box(n)
    local seen = 0
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if line:match("^  %x+ TEXT ") and line:find("drawin screen 1 400x64+0+0", 1, true) then
            seen = seen + 1
            if seen == (n or 1) then
                local x, y, w, h = line:match(" box (%d+),(%d+) (%d+)x(%d+)")
                return {x=tonumber(x), y=tonumber(y), w=tonumber(w), h=tonumber(h)}
            end
        end
    end
end
local function longest(shot, b, from, to)
    local best = 0
    for y = from, to do
        local run = 0
        for x = b.x, b.x + b.w - 1 do
            local r, g, blue = cap:pixel(shot, x, y)
            run = r > 190 and g > 190 and blue > 190 and run + 1 or 0
            best = math.max(best, run)
        end
    end
    return best
end
local function has(shot, b, pred)
    for y = b.y, b.y + b.h - 1 do
        for x = b.x, b.x + b.w - 1 do
            if pred(cap:pixel(shot, x, y)) then return true end
        end
    end
    return false
end
local function is_red(r, g, v) return r > 100 and g < 50 and v < 50 end
local function is_blue(r, g, v) return v > 100 and r < 50 and g < 50 end
local cases = {
    {"colours", "red blue", "<span color='#ff0000'>red</span> <span color='#0000ff'>blue</span>",
        function(shot, b)
            local half = math.floor(b.w / 2)
            check(has(shot, {x=b.x, y=b.y, w=half, h=b.h}, is_red), "first word has red pixels")
            check(has(shot, {x=b.x + half, y=b.y, w=b.w - half, h=b.h}, is_blue),
                "second word has blue pixels")
        end},
    {"lines", "red\nblue\nblue",
        "<span color='#ff0000'>red</span>\n<span color='#0000ff'>blue\nblue</span>",
        function(shot)
            local second, third = box(2), box(3)
            check(second and third, "each line has its own text command")
            if not (second and third) then return end
            check(has(shot, second, is_blue) and not has(shot, second, is_red),
                "second line draws its own span's colour")
            check(has(shot, third, is_blue) and not has(shot, third, is_red),
                "a span across a newline colours the next line")
        end},
    {"underline", "under", "<u>under</u>", function(shot, b)
        local from = b.y + math.floor(b.h * 0.7)
        check(longest(shot, b, from, b.y + b.h - 1) >= b.w - 2,
            "underline extends across the word below its baseline")
    end},
    {"strikethrough", "struck", "<s>struck</s>", function(shot, b)
        local from, to = b.y + math.floor(b.h * 0.3), b.y + math.floor(b.h * 0.7)
        check(longest(shot, b, from, to) > longest(plain_shot, plain_box, from, to) + 5,
            "strikethrough crosses the word continuously")
    end},
    {"background", "bg", "<span background='#00ff00'>bg</span>", function(shot, b)
        check(has(shot, b, function(r, g, v) return g > 200 and r < 30 and v < 30 end),
            "background paints green outside glyphs")
    end},
    {"alpha", "half", "<span alpha='50%'>half</span>", function(shot, b)
        local peak = 0
        for y = b.y, b.y + b.h - 1 do
            for x = b.x, b.x + b.w - 1 do
                local r = cap:pixel(shot, x, y)
                peak = math.max(peak, r)
            end
        end
        check(peak > 90 and peak < 180, "half alpha lies between foreground and background")
    end},
    {"font", "Bold and not", "<b>Bold</b> and not", function(shot)
        check(shot == plain_shot, "font-changing runs use the first font throughout")
    end},
}
local steps = {function()
    label = wibox.widget.textbox()
    bar = wibox {x=0, y=0, width=400, height=64, screen=s,
        bg="#101010", fg="#ffffff", visible=true}
    bar:setup {layout=wibox.layout.fixed.horizontal, label}
    return true
end}
for _, case in ipairs(cases) do
    steps[#steps + 1] = function(count)
        if count == 1 then
            label.font = case[1] == "font" and "sans bold 10" or "sans 10"
            label.text = case[2]
            return nil
        end
        if count < 4 or not box() then return nil end
        plain_box, plain_shot = box(), cap:shot()
        label.font = "sans 10"
        label.markup = case[3]
        return true
    end
    steps[#steps + 1] = function(count)
        if count < 4 or not box() then return nil end
        local b = box()
        check(b.w == plain_box.w, case[1] .. " preserves solved width")
        case[4](cap:shot(), b)
        local messages = log()
        check(not messages:find("no field for", 1, true), case[1] .. " has no unsupported-attribute warning")
        if case[1] ~= "font" then
            check(not messages:find("more than one run", 1, true), case[1] .. " has no multiple-run warning")
        else
            local _, count = messages:gsub("has more than one run and is drawn as one", "")
            check(count == 1, "font changes warn once")
        end
        return true
    end
end
steps[#steps + 1] = function()
    bar.visible = false
    assert(#failures == 0, table.concat(failures, "; "))
    return true
end
runner.run_steps(steps)
