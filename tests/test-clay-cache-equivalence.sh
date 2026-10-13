#!/usr/bin/env bash
#
# The fragment cache equals its recompute: the bundled config dumps the same
# tree with SOMEWM_CLAY_NO_CACHE=1 as without it. Two sandboxed headless
# instances run one after the other through the same recipe (frozen clock,
# tile layout, 0..3 test clients, a close, a tag switch), and every dump is
# compared byte for byte after normalising ids, font ids and frame counters.
#
# Usage: ./tests/test-clay-cache-equivalence.sh [path-to-somewm] [path-to-somewm-client]
#        ./tests/test-clay-cache-equivalence.sh --compare-only OUT_DIR

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
DUMPS="dump-0 dump-1 dump-2 dump-3 dump-close dump-tag"

compare() {
    local out="$1" d rc=0
    for d in $DUMPS; do
        if diff -u "$out/cache-on/$d.norm" "$out/cache-off/$d.norm"; then
            echo "[PASS] $d identical"
        else
            echo "[FAIL] $d differs"
            rc=1
        fi
    done
    return $rc
}

if [ "${1:-}" = --compare-only ]; then
    compare "${2:?out dir}"
    exit $?
fi

export SOMEWM="${1:-$ROOT_DIR/build-test/somewm}"
export SOMEWM_CLIENT="${2:-$ROOT_DIR/build-test/somewm-client}"
. "$ROOT_DIR/tests/restart/lib.sh"

sw_require_helper test-transient-client
out="$BUILD_DIR/cache-equivalence"
rm -rf "$out"

export LUA_PATH="$ROOT_DIR/lua/?.lua;$ROOT_DIR/lua/?/init.lua;$ROOT_DIR/tests/?.lua;;"
export AWESOME_THEMES_PATH="$ROOT_DIR/themes" GIO_USE_VFS=local
export XDG_CONFIG_HOME="$XDG_RUNTIME_DIR/config" XDG_CACHE_HOME="$XDG_RUNTIME_DIR/cache"
export XDG_DATA_HOME="$XDG_RUNTIME_DIR/data" XDG_STATE_HOME="$XDG_RUNTIME_DIR/state"
unset WAYLAND_DISPLAY DISPLAY SOMEWM_SOCKET SOMEWM_CLAY_NO_CACHE
cd "$ROOT_DIR"

FREEZE='local function freeze(w) if w.set_format then w:set_format("Fri Sep 12  09:14") end; for _,child in ipairs(w:get_children()) do freeze(child) end end; freeze(screen.primary.mywibox.widget); return "frozen"'
TREE='(function() local t = {}; for i = 1, screen.count() do t[#t+1] = awesome._clay_tree(screen[i]) end; return table.concat(t, "\n") end)()'

normalise() {
    sed -E -e 's/\b[0-9a-f]{8}\b/ID/g' -e 's/font=[0-9]+/font=N/g' \
        -e 's/\b(frames|commands|mutations|nodes|raster_bytes|buffers|elements|map|free|inspector_input) [0-9]+(\/[0-9]+)?/\1 N/g' \
        -e 's/\b(declare|solve|reconcile) [0-9]+us/\1 Nus/g' "$1" > "${1%.txt}.norm"
}

dump() {
    local name="$1" file="$out/$1/$2.txt"
    if sw_eval "$name" "return $TREE"; then
        printf '%s\n' "$EVAL_VALUE" > "$file"
        normalise "$file"
    else
        fail "$name $2" "$EVAL_ERROR"
    fi
}

run_recipe() {
    local name="$1" expect_env="$2" n
    mkdir -p "$out/$name"
    sw_start "$name" --config "$ROOT_DIR/somewmrc.lua" --no-marker || finish
    check_eval "$name" "$name SOMEWM_CLAY_NO_CACHE" 'return tostring(os.getenv("SOMEWM_CLAY_NO_CACHE"))' "$expect_env"
    check_eval "$name" "$name clock frozen" "$FREEZE" frozen
    check_eval "$name" "$name tile layout" 'screen.primary.selected_tag.layout = require("awful").layout.suit.tile; return "tile"' tile
    for n in 0 1 2 3; do
        if [ "$n" -gt 0 ]; then
            "$SOMEWM_CLIENT" test run --name "$name" -- "$SW_HELPER" "CLIENT_$n" \
                > "$out/$name/client-$n.log" 2>&1 &
            sw_bg $!
            sw_eval_retry "$name" "assert($TREE:find('SURFACE CLIENT_$n ', 1, true)); return 'ok'" 15 \
                || fail "$name CLIENT_$n in the dump" "$EVAL_ERROR"
        fi
        dump "$name" "dump-$n"
    done
    check_eval "$name" "$name kill CLIENT_3" 'for _, c in ipairs(client.get()) do if c.class == "CLIENT_3" then c:kill() end end; return "killed"' killed
    sw_eval_retry "$name" "for _, c in ipairs(client.get()) do assert(c.class ~= 'CLIENT_3') end; assert(not $TREE:find('SURFACE CLIENT_3 ', 1, true)); return 'ok'" \
        || fail "$name CLIENT_3 gone" "$EVAL_ERROR"
    dump "$name" dump-close
    check_eval "$name" "$name viewnext" 'require("awful").tag.viewnext(screen.primary); return "next"' next
    sw_eval_retry "$name" "assert(not $TREE:find('SURFACE CLIENT_', 1, true)); return 'ok'" \
        || fail "$name clients hidden" "$EVAL_ERROR"
    dump "$name" dump-tag
    cp "$(sw_log "$name")" "$out/$name/somewm.log" 2>/dev/null
    sw_stop "$name"
}

echo "== cache on"
run_recipe cache-on nil
echo "== cache off"
export SOMEWM_CLAY_NO_CACHE=1
run_recipe cache-off 1

for d in $DUMPS; do
    info "$d: $(wc -l < "$out/cache-on/$d.txt" 2>/dev/null) lines"
done
compare "$out" || fail "cache-on and cache-off dumps differ" "see the diff above and $out"
finish
