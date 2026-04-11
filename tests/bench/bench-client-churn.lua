-- Benchmark: Client Churn (Signal-only)
--
-- Tests property toggle signal overhead with full compositor pipeline
-- per iteration. Each iteration: toggle 6 properties on all clients ->
-- yield -> some_refresh() processes property signals, banning, stacking.
--
-- Run: somewm-client eval "dofile('tests/bench/bench-client-churn.lua')"
-- Then poll: somewm-client eval "return _bench_results.client_churn or 'PENDING'"

local helpers = dofile("tests/bench/bench-helpers.lua")

local N = 100

_G._bench_results = _G._bench_results or {}
_G._bench_results.client_churn = nil

local clients = client.get()
if #clients == 0 then
    return "SKIP: no clients available"
end

helpers.timed_async("client-churn", function(i)
    for _, c in ipairs(clients) do
        c.minimized = true
        c.minimized = false
        c.sticky = true
        c.sticky = false
        c.ontop = true
        c.ontop = false
    end
end, N, function(result)
    _G._bench_results.client_churn = helpers.format_results("client-churn", {result}, {
        clients = #clients,
        property_toggles_per_iteration = #clients * 6,
    })
end)

return "ASYNC client-churn started (" .. N .. " iterations, " .. #clients .. " clients)"
