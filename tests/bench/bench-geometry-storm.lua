-- Benchmark: Geometry Storm
--
-- Tests the geometry signal burst path. On synchronous dispatch, each
-- geometry change emits up to 7 signals (property::geometry, position,
-- size, x, y, width, height). On queued dispatch with coalescing, this
-- should collapse to 1.
--
-- Run: somewm-client eval "dofile('tests/bench/bench-geometry-storm.lua')"

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
        c:geometry({
            x = 10 + (i % 200),
            y = 10 + (i % 200),
            width = 400 + (i % 100),
            height = 300 + (i % 100),
        })
    end
end

local elapsed = os.clock() - start

collectgarbage("restart")

out[#out+1] = "=== geometry-storm ==="
out[#out+1] = string.format("clients: %d, iterations: %d", #clients, N)
out[#out+1] = string.format("elapsed: %.4f seconds", elapsed)
out[#out+1] = string.format("ops/sec: %.0f", (N * #clients) / elapsed)

if has_bench then
    local s = awesome.bench_stats()
    out[#out+1] = string.format("signal_emit_count: %d", s.signal_emit_count)
    out[#out+1] = string.format("signal_handler_calls: %d", s.signal_handler_calls)
    out[#out+1] = string.format("signal_lookup_misses: %d", s.signal_lookup_misses)
    out[#out+1] = string.format("refresh_count: %d", s.refresh_count)
    out[#out+1] = string.format("lua_memory_kb: %.1f", s.lua_memory_kb)
end

return table.concat(out, "\n")
