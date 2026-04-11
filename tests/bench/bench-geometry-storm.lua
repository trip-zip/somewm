-- Benchmark: Geometry Storm
--
-- Tests geometry changes with full compositor pipeline per iteration.
-- Each iteration: set geometry on all clients -> yield -> some_refresh()
-- applies geometry to scene graph, recalculates borders, etc.
--
-- Run: somewm-client eval "dofile('tests/bench/bench-geometry-storm.lua')"
-- Then poll: somewm-client eval "return _bench_results.geometry_storm or 'PENDING'"

local helpers = dofile("tests/bench/bench-helpers.lua")

local N = 100

_G._bench_results = _G._bench_results or {}
_G._bench_results.geometry_storm = nil

local clients = client.get()
if #clients == 0 then
    return "SKIP: no clients available"
end

helpers.timed_async("geometry-storm", function(i)
    for _, c in ipairs(clients) do
        c:geometry({
            x = 10 + (i % 200),
            y = 10 + (i % 200),
            width = 400 + (i % 100),
            height = 300 + (i % 100),
        })
    end
end, N, function(result)
    _G._bench_results.geometry_storm = helpers.format_results("geometry-storm", {result}, {
        clients = #clients,
    })
end)

return "ASYNC geometry-storm started (" .. N .. " iterations, " .. #clients .. " clients)"
