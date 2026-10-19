local runner = require("_runner")
local spawn = require("awful.spawn")
local lgi = require("lgi")
local Gio = lgi.Gio

local cases = {
    { text = "", close = true, lines = {} },
    { text = "first\n\nlast", close = true, lines = { "first", "", "last" } },
    { text = "kept\n", close = false, lines = { "kept" } },
}
local completed = 0
local async_result
local callback_lines = {}
local callback_done = 0
local process_done = false

runner.run_steps({
    function()
        for _, case in ipairs(cases) do
            local input = Gio.MemoryInputStream.new_from_bytes(lgi.GLib.Bytes.new(case.text))
            case.input = input
            case.received = {}
            spawn.read_lines(input, function(line)
                table.insert(case.received, line)
            end, function()
                assert(input:is_closed() == case.close)
                completed = completed + 1
            end, case.close)
        end
        spawn.easy_async({ "sh", "-c", "printf 'out\\n'; printf 'err\\n' >&2" },
            function(stdout, stderr, reason, code)
                async_result = { stdout, stderr, reason, code }
            end)
        spawn.with_line_callback({ "sh", "-c", "printf 'one\\ntwo\\n'" }, {
            stdout = function(line) table.insert(callback_lines, line) end,
            output_done = function() callback_done = callback_done + 1 end,
            exit = function(reason, code)
                assert(reason == "exit" and code == 0)
                process_done = true
            end,
        })
        return true
    end,
    function()
        if completed ~= #cases or not async_result or callback_done == 0 or not process_done then
            return
        end
        for _, case in ipairs(cases) do
            assert(#case.received == #case.lines)
            for i, line in ipairs(case.lines) do
                assert(case.received[i] == line)
            end
            if not case.close then case.input:close() end
        end
        assert(async_result[1] == "out\n" and async_result[2] == "err\n")
        assert(async_result[3] == "exit" and async_result[4] == 0)
        assert(callback_done == 1)
        assert(#callback_lines == 2 and callback_lines[1] == "one" and callback_lines[2] == "two")
        return true
    end,
})
