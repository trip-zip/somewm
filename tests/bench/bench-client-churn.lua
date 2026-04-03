-- Benchmark: Client Churn (Signal-only)
--
-- Tests the signal overhead of client property changes without actually
-- spawning/destroying clients (which is slow and I/O-bound). Instead,
-- this rapidly toggles client properties that each emit signals:
-- minimized, sticky, ontop, urgent, fullscreen, maximized.
--
-- Run: somewm-client eval "dofile('tests/bench/bench-client-churn.lua')"

local N = 1000
local has_bench = awesome.bench_stats ~= nil
local out = {}

if has_bench then
    awesome.bench_reset()
end

collectgarbage("collect")
collectgarbage("stop")

local clients = client.get()
if #clients == 0 then
    collectgarbage("restart")
    return "SKIP: no clients available"
end

local start = os.clock()

for i = 1, N do
    for _, c in ipairs(clients) do
        c.minimized = true
        c.minimized = false
        c.sticky = true
        c.sticky = false
        c.ontop = true
        c.ontop = false
    end
end

local elapsed = os.clock() - start

collectgarbage("restart")

-- 6 property toggles per client per iteration
local total_ops = N * #clients * 6

out[#out+1] = "=== client-churn ==="
out[#out+1] = string.format("clients: %d, iterations: %d, property toggles: %d", #clients, N, total_ops)
out[#out+1] = string.format("elapsed: %.4f seconds", elapsed)
out[#out+1] = string.format("ops/sec: %.0f", total_ops / elapsed)

if has_bench then
    local s = awesome.bench_stats()
    out[#out+1] = string.format("signal_emit_count: %d", s.signal_emit_count)
    out[#out+1] = string.format("signal_handler_calls: %d", s.signal_handler_calls)
    out[#out+1] = string.format("signal_lookup_misses: %d", s.signal_lookup_misses)
    out[#out+1] = string.format("refresh_count: %d", s.refresh_count)
    out[#out+1] = string.format("lua_memory_kb: %.1f", s.lua_memory_kb)
end

return table.concat(out, "\n")
