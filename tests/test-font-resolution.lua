local runner = require("_runner")
local lgi = require("lgi")

runner.run_steps({
    function()
        local font_map = lgi.PangoCairo.FontMap.get_default()
        local context = font_map:create_context()
        for _, case in ipairs({
            { "sans 8", "Noto Sans CJK KR" },
            { "monospace 10", "Noto Sans Mono CJK KR" },
        }) do
            local description = lgi.Pango.FontDescription.from_string(case[1])
            local font = assert(font_map:load_font(context, description))
            local family = font:describe():get_family()
            io.stderr:write(case[1] .. " resolved to " .. family .. "\n")
            assert(family == case[2], case[1] .. ": expected " .. case[2]
                .. ", got " .. family)
        end
        return true
    end,
})
