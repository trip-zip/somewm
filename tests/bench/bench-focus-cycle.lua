-- Benchmark: Focus Cycling
--
-- Tests focus changes with full compositor pipeline per iteration.
-- Each iteration: change focus -> yield -> some_refresh() processes
-- focus signals, stacking updates, border redraws.
--
-- Run: somewm-client eval "dofile('tests/bench/bench-focus-cycle.lua')"
-- Then poll: somewm-client eval "return _bench_results.focus_cycle or 'PENDING'"

local helpers = dofile("tests/bench/bench-helpers.lua")

local N = 100

_G._bench_results = _G._bench_results or {}
_G._bench_results.focus_cycle = nil

local clients = client.get()
if #clients < 2 then
    return "SKIP: need at least 2 clients"
end

helpers.timed_async("focus-cycle", function(i)
    local c = clients[(i % #clients) + 1]
    client.focus = c
end, N, function(result)
    _G._bench_results.focus_cycle = helpers.format_results("focus-cycle", {result}, {
        clients = #clients,
    })
end)

return "ASYNC focus-cycle started (" .. N .. " iterations, " .. #clients .. " clients)"
