local runner = require("_runner")
local spawn = require("awful.spawn")

local async_spawns_done = 0

-- Corner cases for spawn.easy_async: {command, expected stdout, expected stderr}
local easy_async_cases = {
    -- No output at all
    { "true", "", "" },
    -- A single empty line
    { "echo; echo >&2", "\n", "\n" },
    { "echo out1; echo out2; echo err >&2", "out1\nout2\n", "err\n" },
    -- A missing newline at the end is added
    { "printf out; printf err >&2", "out\n", "err\n" },
    -- A trailing empty line is kept
    { "printf 'out\\n\\n'; printf 'err\\n\\n' >&2", "out\n\n", "err\n\n" },
}

runner.run_steps({
    function(count)
        if count == 1 then
            for _, case in ipairs(easy_async_cases) do
                local cmd, exp_stdout, exp_stderr = case[1], case[2], case[3]
                spawn.easy_async({"sh", "-c", cmd}, function(stdout, stderr, reason, code)
                    assert(stdout == exp_stdout, cmd .. ": stdout == '" .. stdout .. "'")
                    assert(stderr == exp_stderr, cmd .. ": stderr == '" .. stderr .. "'")
                    assert(reason == "exit" and code == 0, cmd)
                    async_spawns_done = async_spawns_done + 1
                end)
            end
        end
        if async_spawns_done == #easy_async_cases then
            return true
        end
    end,
})
