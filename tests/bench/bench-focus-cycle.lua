-- Benchmark: Focus Cycling
--
-- Tests the focus signal burst path. Each focus change emits up to 6
-- signals: property::active(false) + unfocus + client::unfocus on old,
-- property::active(true) + focus + client::focus on new.
--
-- Run: somewm-client eval "dofile('tests/bench/bench-focus-cycle.lua')"

local N = 5000
local has_bench = awesome.bench_stats ~= nil
local out = {}

if has_bench then
    awesome.bench_reset()
end

collectgarbage("collect")
collectgarbage("stop")

local clients = client.get()
if #clients < 2 then
    collectgarbage("restart")
    return "SKIP: need at least 2 clients"
end

local start = os.clock()

for i = 1, N do
    local c = clients[(i % #clients) + 1]
    client.focus = c
end

local elapsed = os.clock() - start

collectgarbage("restart")

out[#out+1] = "=== focus-cycle ==="
out[#out+1] = string.format("clients: %d, iterations: %d", #clients, N)
out[#out+1] = string.format("elapsed: %.4f seconds", elapsed)
out[#out+1] = string.format("ops/sec: %.0f", N / elapsed)

if has_bench then
    local s = awesome.bench_stats()
    out[#out+1] = string.format("signal_emit_count: %d", s.signal_emit_count)
    out[#out+1] = string.format("signal_handler_calls: %d", s.signal_handler_calls)
    out[#out+1] = string.format("signal_lookup_misses: %d", s.signal_lookup_misses)
    out[#out+1] = string.format("refresh_count: %d", s.refresh_count)
    out[#out+1] = string.format("lua_memory_kb: %.1f", s.lua_memory_kb)
end

return table.concat(out, "\n")
