#!/usr/bin/env bash

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER
box=$(sw_sandbox)
cat > "$box/rc.lua" <<'LUA'
dofile(os.getenv("SOMEWM_TEST_BASE_RC"))
local awful = require("awful")
local wibox = require("wibox")
awful.screen.connect_for_each_screen(function(s)
    s.testbar = awful.wibar({screen = s, position = "top", height = 24})
    s.testbar:setup({text = "Reload", widget = wibox.widget.textbox})
end)
LUA

sw_start hr-dump --config "$box/rc.lua" || finish
sw_spawn hr-dump "$CLIENT" || finish
check_client_appeared hr-dump fullscreen_test || finish
sw_spawn hr-dump "$CLIENT" || finish
sw_wait_true hr-dump 'return tostring(#client.get() == 2)' 10
check_eval hr-dump "two clients and the wibar are present" \
    'return tostring(#client.get() == 2 and screen.primary.testbar.visible)' true
check_eval hr-dump "place clients inside the workarea" \
    'for i, c in ipairs(client.get()) do c:geometry({x = 40 + i * 240, y = 80, width = 200, height = 200}) end; return true' true

DUMP='return awesome._clay_tree(screen.primary)'
cat > "$box/normalize.lua" <<'LUA'
return function(root, path)
    local f = assert(io.open(path))
    local dump = f:read("*a")
    f:close()
    local shape = dofile(root .. "/tests/_clay_golden.lua").shape(dump)
    shape = shape:gsub("floating %d+", "floating N"):gsub("font=%d+", "font=N")
    local realized = assert(dump:match("  realized:\n(.*)"))
    for line in realized:gmatch("[^\n]+") do
        if not line:find(" cursor ", 1, true) then
            shape = shape .. line:gsub("^  %x%x%x%x%x%x%x%x ", "  ") .. "\n"
        end
    end
    return shape
end
LUA
dump_dir="$ROOT_DIR/build-test/restart-artifacts/$TEST_NAME-$(basename "$BUILD_DIR")"
mkdir -p "$dump_dir"

capture() {
    local phase="$1"
    if ! sw_eval hr-dump "$DUMP"; then
        fail "$phase dump is readable" "$EVAL_ERROR"
        return 1
    fi
    printf '%s\n' "$EVAL_VALUE" > "$dump_dir/dump-$phase.txt"
    if ! sw_eval hr-dump "return dofile('$box/normalize.lua')('$ROOT_DIR', '$dump_dir/dump-$phase.txt')"; then
        fail "$phase dump can be normalized" "$EVAL_ERROR"
        return 1
    fi
    printf '%s\n' "$EVAL_VALUE" > "$dump_dir/dump-$phase.normalized.txt"
    grep 'CLIENT' "$dump_dir/dump-$phase.txt" > "$dump_dir/dump-$phase.clients.txt"
    check_match "$phase dump contains CLIENT elements" \
        "$(cat "$dump_dir/dump-$phase.clients.txt")" 'CLIENT'
}

capture before || finish
sw_reload hr-dump || finish
capture after || finish

for kind in normalized clients; do
    if diff -u "$dump_dir/dump-before.$kind.txt" "$dump_dir/dump-after.$kind.txt"; then
        pass "$kind dumps are identical across reload"
    else
        fail "$kind dumps are identical across reload"
    fi
done
sw_check_log_clean hr-dump "post-reload log"
finish
