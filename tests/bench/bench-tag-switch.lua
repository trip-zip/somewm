-- Benchmark: Tag Switching
--
-- Tests the tag view path which triggers property::selected on tags,
-- client list signals, and banning/unbanning of clients. This exercises
-- a mix of property, lifecycle, and layout signals.
--
-- Run: somewm-client eval "dofile('tests/bench/bench-tag-switch.lua')"

local N = 1000
local has_bench = awesome.bench_stats ~= nil
local out = {}

if has_bench then
    awesome.bench_reset()
end

collectgarbage("collect")
collectgarbage("stop")

local s = screen[1]
if not s or not s.tags or #s.tags < 2 then
    collectgarbage("restart")
    return "SKIP: need at least 2 tags on screen 1"
end

local tags = s.tags
local ntags = #tags

local start = os.clock()

for i = 1, N do
    local tag_idx = (i % ntags) + 1
    tags[tag_idx]:view_only()
end

local elapsed = os.clock() - start

-- Restore tag 1
tags[1]:view_only()

collectgarbage("restart")

out[#out+1] = "=== tag-switch ==="
out[#out+1] = string.format("tags: %d, iterations: %d", ntags, N)
out[#out+1] = string.format("elapsed: %.4f seconds", elapsed)
out[#out+1] = string.format("ops/sec: %.0f", N / elapsed)

if has_bench then
    local st = awesome.bench_stats()
    out[#out+1] = string.format("signal_emit_count: %d", st.signal_emit_count)
    out[#out+1] = string.format("signal_handler_calls: %d", st.signal_handler_calls)
    out[#out+1] = string.format("signal_lookup_misses: %d", st.signal_lookup_misses)
    out[#out+1] = string.format("refresh_count: %d", st.refresh_count)
    out[#out+1] = string.format("lua_memory_kb: %.1f", st.lua_memory_kb)
end

return table.concat(out, "\n")
