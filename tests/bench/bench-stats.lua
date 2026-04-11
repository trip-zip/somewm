#!/usr/bin/env lua
--
-- Statistical comparison of two benchmark result sets.
-- Reads JSON files from two directories, extracts ops_per_sec from each run,
-- computes mean/stddev/change and Welch's t-test for significance.
--
-- Usage: lua bench-stats.lua <dir-A> <dir-B>

local dir_a = arg[1]
local dir_b = arg[2]

if not dir_a or not dir_b then
    io.stderr:write("Usage: lua bench-stats.lua <dir-A> <dir-B>\n")
    os.exit(1)
end

-- ---------------------------------------------------------------------------
-- Minimal JSON parser (handles the subset we emit)
-- ---------------------------------------------------------------------------

local function skip_ws(s, i)
    return s:match("^%s*()", i)
end

local function parse_value(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)

    if c == '"' then
        -- String
        local j = i + 1
        while true do
            local k = s:find('[\\"]', j)
            if not k then error("unterminated string at " .. i) end
            if s:sub(k, k) == '\\' then
                j = k + 2
            else
                return s:sub(i + 1, k - 1), k + 1
            end
        end
    elseif c == '{' then
        -- Object
        local obj = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == '}' then return obj, i + 1 end
        while true do
            local key
            key, i = parse_value(s, i)
            i = skip_ws(s, i)
            assert(s:sub(i, i) == ':', "expected ':' at " .. i)
            i = skip_ws(s, i + 1)
            local val
            val, i = parse_value(s, i)
            obj[key] = val
            i = skip_ws(s, i)
            local sep = s:sub(i, i)
            if sep == '}' then return obj, i + 1 end
            assert(sep == ',', "expected ',' or '}' at " .. i)
            i = skip_ws(s, i + 1)
        end
    elseif c == '[' then
        -- Array
        local arr = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == ']' then return arr, i + 1 end
        while true do
            local val
            val, i = parse_value(s, i)
            arr[#arr + 1] = val
            i = skip_ws(s, i)
            local sep = s:sub(i, i)
            if sep == ']' then return arr, i + 1 end
            assert(sep == ',', "expected ',' or ']' at " .. i)
            i = skip_ws(s, i + 1)
        end
    elseif s:match("^true", i) then
        return true, i + 4
    elseif s:match("^false", i) then
        return false, i + 5
    elseif s:match("^null", i) then
        return nil, i + 4
    else
        -- Number
        local num_str = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if not num_str then error("invalid value at " .. i) end
        return tonumber(num_str), i + #num_str
    end
end

local function json_decode(s)
    local val, _ = parse_value(s, 1)
    return val
end

-- ---------------------------------------------------------------------------
-- Statistics
-- ---------------------------------------------------------------------------

local function mean(values)
    local sum = 0
    for _, v in ipairs(values) do sum = sum + v end
    return sum / #values
end

local function stddev(values, m)
    m = m or mean(values)
    local sum_sq = 0
    for _, v in ipairs(values) do sum_sq = sum_sq + (v - m) ^ 2 end
    return math.sqrt(sum_sq / (#values - 1))
end

-- Welch's t-test: returns t statistic and approximate degrees of freedom
local function welch_t(m1, s1, n1, m2, s2, n2)
    local se = math.sqrt(s1^2/n1 + s2^2/n2)
    if se == 0 then return 0, 1 end
    local t = (m1 - m2) / se
    local num = (s1^2/n1 + s2^2/n2)^2
    local den = (s1^2/n1)^2/(n1-1) + (s2^2/n2)^2/(n2-1)
    local df = num / den
    return t, df
end

-- Approximate two-tailed p-value from t and df using the beta distribution
-- approximation. For our purposes, we just check against common thresholds.
local function is_significant(t, df, alpha)
    alpha = alpha or 0.05
    -- Critical t-values for common df ranges at alpha=0.05 (two-tailed)
    local crit
    if df >= 120 then crit = 1.980
    elseif df >= 60 then crit = 2.000
    elseif df >= 30 then crit = 2.042
    elseif df >= 20 then crit = 2.086
    elseif df >= 15 then crit = 2.131
    elseif df >= 10 then crit = 2.228
    elseif df >= 5 then crit = 2.571
    elseif df >= 3 then crit = 3.182
    elseif df >= 2 then crit = 4.303
    else crit = 12.706
    end
    return math.abs(t) > crit
end

-- ---------------------------------------------------------------------------
-- Load results from a directory
-- ---------------------------------------------------------------------------

local function list_json_files(dir)
    if dir:match("[%$`|;&(){}!#]") then
        io.stderr:write("Error: unsafe characters in path: " .. dir .. "\n")
        os.exit(1)
    end
    local files = {}
    local p = io.popen("find '" .. dir .. "' -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort")
    if not p then return files end
    for line in p:lines() do
        files[#files + 1] = line
    end
    p:close()
    return files
end

local function load_results(dir)
    -- Group results by benchmark name -> list of ops_per_sec values
    local benchmarks = {}
    local files = list_json_files(dir)

    for _, fpath in ipairs(files) do
        local fname = fpath:match("([^/]+)%.json$")
        if fname and fname ~= "manifest" and fname ~= "startup-time" then
            local f = io.open(fpath, "r")
            if f then
                local content = f:read("*a")
                f:close()
                local ok, data = pcall(json_decode, content)
                if ok and data and data.results then
                    for _, r in ipairs(data.results) do
                        local key = r.name or fname
                        if not benchmarks[key] then benchmarks[key] = {} end
                        if r.ops_per_sec then
                            table.insert(benchmarks[key], r.ops_per_sec)
                        end
                    end
                end
            end
        end
    end

    return benchmarks
end

-- ---------------------------------------------------------------------------
-- Compare and report
-- ---------------------------------------------------------------------------

local results_a = load_results(dir_a)
local results_b = load_results(dir_b)

-- Collect all benchmark names
local all_names = {}
local seen = {}
for name, _ in pairs(results_a) do
    if not seen[name] then
        all_names[#all_names + 1] = name
        seen[name] = true
    end
end
for name, _ in pairs(results_b) do
    if not seen[name] then
        all_names[#all_names + 1] = name
        seen[name] = true
    end
end
table.sort(all_names)

-- Header
local fmt = "%-40s %12s %12s %8s %5s"
print(string.format(fmt, "Benchmark", "Baseline", "Candidate", "Change", "Sig?"))
print(string.rep("-", 80))

local regressions = 0

for _, name in ipairs(all_names) do
    local va = results_a[name]
    local vb = results_b[name]

    if va and vb and #va >= 2 and #vb >= 2 then
        local m_a = mean(va)
        local s_a = stddev(va, m_a)
        local m_b = mean(vb)
        local s_b = stddev(vb, m_b)
        local pct = (m_b - m_a) / m_a * 100

        local t, df = welch_t(m_a, s_a, #va, m_b, s_b, #vb)
        local sig = is_significant(t, df)

        local sig_str = sig and "YES" or "no"
        local a_str = string.format("%.0f +/- %.0f", m_a, s_a)
        local b_str = string.format("%.0f +/- %.0f", m_b, s_b)
        local pct_str = string.format("%+.1f%%", pct)

        print(string.format(fmt, name, a_str, b_str, pct_str, sig_str))

        -- A significant decrease in ops/sec is a regression
        if sig and pct < -5 then
            regressions = regressions + 1
        end
    elseif va and not vb then
        print(string.format(fmt, name, "present", "MISSING", "-", "-"))
    elseif vb and not va then
        print(string.format(fmt, name, "MISSING", "present", "-", "-"))
    else
        local n_a = va and #va or 0
        local n_b = vb and #vb or 0
        print(string.format(fmt, name,
            n_a .. " runs", n_b .. " runs", "n/a", "n/a"))
    end
end

print("")
if regressions > 0 then
    print(string.format("REGRESSIONS: %d benchmark(s) showed significant performance decrease (>5%%)", regressions))
    os.exit(1)
else
    print("No significant regressions detected.")
end
