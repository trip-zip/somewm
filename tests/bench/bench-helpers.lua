-- Shared helpers for somewm benchmarks
--
-- Provides mock objects, timing utilities, and output formatting.

local helpers = {}

-- ---------------------------------------------------------------------------
-- Timing
-- ---------------------------------------------------------------------------

--- Run a function for the given number of iterations and return timing data.
-- Pauses GC during measurement. If awesome.bench_stats is available, captures
-- before/after stats.
function helpers.timed(name, fn, iterations)
    iterations = iterations or 1000

    local has_bench = awesome.bench_stats ~= nil
    if has_bench then awesome.bench_reset() end

    collectgarbage("collect")
    collectgarbage("stop")

    local start = os.clock()
    for _ = 1, iterations do
        fn()
    end
    local elapsed = os.clock() - start

    collectgarbage("restart")

    local result = {
        name = name,
        iterations = iterations,
        elapsed = elapsed,
        ops_per_sec = iterations / elapsed,
    }

    if has_bench then
        result.bench_stats = awesome.bench_stats()
    end

    return result
end

--- Run a function asynchronously, yielding to the event loop between iterations.
-- Each iteration gets a full some_refresh() cycle (layout, geometry, banning, stacking).
-- Results are delivered via done_callback since IPC eval returns before completion.
-- GC runs normally since we're measuring realistic compositor cost.
function helpers.timed_async(name, fn, iterations, done_callback)
    local gears_timer = require("gears.timer")
    iterations = iterations or 100

    local has_bench = awesome.bench_stats ~= nil
    if has_bench then awesome.bench_reset() end

    collectgarbage("collect")

    local i = 0
    local start = os.clock()

    local function next_iteration()
        if i < iterations then
            i = i + 1
            fn(i)
            gears_timer.delayed_call(next_iteration)
        else
            local elapsed = os.clock() - start
            local result = {
                name = name,
                iterations = iterations,
                elapsed = elapsed,
                ops_per_sec = iterations / elapsed,
            }
            if has_bench then
                result.bench_stats = awesome.bench_stats()
            end
            done_callback(result)
        end
    end

    gears_timer.delayed_call(next_iteration)
end

-- Global results table for async benchmarks (polled by runner)
if not _G._bench_results then
    _G._bench_results = {}
end

-- ---------------------------------------------------------------------------
-- JSON encoder
-- ---------------------------------------------------------------------------

local function json_encode_value(v, indent, depth)
    depth = depth or 0
    indent = indent or ""
    local t = type(v)

    if t == "number" then
        if v ~= v then return '"NaN"' end
        if v == math.huge then return '"Infinity"' end
        if v == -math.huge then return '"-Infinity"' end
        return string.format("%.6g", v)
    elseif t == "string" then
        return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        -- Check if array (sequential integer keys starting at 1)
        local is_array = true
        local max_i = 0
        for k, _ in pairs(v) do
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
                is_array = false
                break
            end
            if k > max_i then max_i = k end
        end
        if max_i ~= #v then is_array = false end

        local next_indent = indent .. "  "
        local parts = {}

        if is_array and #v > 0 then
            for i = 1, #v do
                parts[#parts + 1] = next_indent .. json_encode_value(v[i], next_indent, depth + 1)
            end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
        elseif not is_array then
            -- Collect and sort keys for deterministic output
            local keys = {}
            for k, _ in pairs(v) do
                keys[#keys + 1] = k
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

            for _, k in ipairs(keys) do
                local key_str = json_encode_value(tostring(k), next_indent, depth + 1)
                local val_str = json_encode_value(v[k], next_indent, depth + 1)
                parts[#parts + 1] = next_indent .. key_str .. ": " .. val_str
            end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
        else
            return "[]"
        end
    else
        return '"<' .. t .. '>"'
    end
end

function helpers.json_encode(v)
    return json_encode_value(v)
end

-- ---------------------------------------------------------------------------
-- Output formatting
-- ---------------------------------------------------------------------------

--- Format a list of results as human-readable text and JSON.
-- @param benchmark_name  The name of the benchmark
-- @param results         Array of result tables from helpers.timed()
-- @param extra           Optional table of extra metadata to include in JSON
-- @return string         Combined human-readable + JSON output
function helpers.format_results(benchmark_name, results, extra)
    local out = {}

    -- Human-readable output
    out[#out + 1] = "=== " .. benchmark_name .. " ==="

    for _, r in ipairs(results) do
        out[#out + 1] = string.format("  %s: %.4fs (%s iterations, %.0f ops/sec)",
            r.name, r.elapsed, r.iterations, r.ops_per_sec)
    end

    -- Build JSON payload
    local json_data = {
        benchmark = benchmark_name,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        results = {},
    }

    if extra then
        for k, v in pairs(extra) do
            json_data[k] = v
        end
    end

    for _, r in ipairs(results) do
        local entry = {
            name = r.name,
            iterations = r.iterations,
            elapsed = r.elapsed,
            ops_per_sec = r.ops_per_sec,
        }
        if r.bench_stats then
            entry.bench_stats = r.bench_stats
        end
        json_data.results[#json_data.results + 1] = entry
    end

    out[#out + 1] = ""
    out[#out + 1] = "---JSON-START---"
    out[#out + 1] = helpers.json_encode(json_data)
    out[#out + 1] = "---JSON-END---"

    return table.concat(out, "\n")
end

return helpers
