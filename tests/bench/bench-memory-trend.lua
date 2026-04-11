-- Benchmark: Memory Trend Sampler
--
-- Installs a periodic timer to sample memory stats. Driven externally
-- by bench-memory-runner.sh which sends load patterns via IPC.
--
-- Usage (internal): somewm-client eval "dofile('tests/bench/bench-memory-trend.lua')"
-- This starts the sampler. Call bench_memory_stop() via IPC to get results.

local helpers = dofile("tests/bench/bench-helpers.lua")
local gears = require("gears")

local SAMPLE_INTERVAL = 5  -- seconds

local samples = {}
local timer_obj = nil
local start_time = os.clock()

local function take_sample()
    local sample = {
        time_s = os.clock() - start_time,
        lua_memory_kb = collectgarbage("count"),
    }

    if awesome.bench_stats then
        local s = awesome.bench_stats()
        sample.lua_memory_kb = s.lua_memory_kb or sample.lua_memory_kb
        if s.memory then
            sample.scene_trees = s.memory.scene_trees
            sample.scene_rects = s.memory.scene_rects
            sample.scene_buffers = s.memory.scene_buffers
            sample.clients = s.memory.clients
            sample.drawins = s.memory.drawins
        end
    end

    samples[#samples + 1] = sample
end

-- Start sampling
timer_obj = gears.timer {
    timeout = SAMPLE_INTERVAL,
    autostart = true,
    callback = take_sample,
}

-- Take initial sample immediately
take_sample()

-- Global function to stop and return results
function bench_memory_stop() -- luacheck: ignore
    if timer_obj then
        timer_obj:stop()
        timer_obj = nil
    end

    -- Take final sample
    take_sample()

    local n = #samples
    if n < 2 then
        return helpers.json_encode({
            benchmark = "memory-trend",
            error = "not enough samples",
        })
    end

    -- Compute linear regression on lua_memory_kb
    local sum_x, sum_y, sum_xy, sum_x2 = 0, 0, 0, 0
    for _, s in ipairs(samples) do
        sum_x = sum_x + s.time_s
        sum_y = sum_y + s.lua_memory_kb
        sum_xy = sum_xy + s.time_s * s.lua_memory_kb
        sum_x2 = sum_x2 + s.time_s ^ 2
    end
    local denom = n * sum_x2 - sum_x ^ 2
    local slope = denom ~= 0 and (n * sum_xy - sum_x * sum_y) / denom or 0
    local slope_kb_per_min = slope * 60

    local result = {
        benchmark = "memory-trend",
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        sample_count = n,
        duration_s = samples[n].time_s,
        start_lua_kb = samples[1].lua_memory_kb,
        end_lua_kb = samples[n].lua_memory_kb,
        slope_kb_per_min = slope_kb_per_min,
        samples = samples,
    }

    return helpers.json_encode(result)
end

return string.format("Memory sampler started (interval: %ds). Call bench_memory_stop() to get results.", SAMPLE_INTERVAL)
