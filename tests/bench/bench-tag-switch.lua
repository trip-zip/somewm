-- Benchmark: Tag Switching
--
-- Tests the tag view path with full compositor pipeline per iteration.
-- Each iteration: switch tag -> yield -> some_refresh() runs layout,
-- banning, stacking, geometry application.
--
-- Run: somewm-client eval "dofile('tests/bench/bench-tag-switch.lua')"
-- Then poll: somewm-client eval "return _bench_results.tag_switch or 'PENDING'"

local helpers = dofile("tests/bench/bench-helpers.lua")

local N = 100

_G._bench_results = _G._bench_results or {}
_G._bench_results.tag_switch = nil

local s = screen[1]
if not s or not s.tags or #s.tags < 2 then
    return "SKIP: need at least 2 tags on screen 1"
end

local tags = s.tags
local ntags = #tags

helpers.timed_async("tag-switch", function(i)
    local tag_idx = (i % ntags) + 1
    tags[tag_idx]:view_only()
end, N, function(result)
    tags[1]:view_only()
    _G._bench_results.tag_switch = helpers.format_results("tag-switch", {result}, {
        tags = ntags,
    })
end)

return "ASYNC tag-switch started (" .. N .. " iterations)"
