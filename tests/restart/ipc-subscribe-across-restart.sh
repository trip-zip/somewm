#!/usr/bin/env bash
#
# An IPC event subscription must keep delivering after a hot-reload.
#
# The socket and the per-fd subscribed flag live in C (ipc.c) and do survive.
# But the subscriber registry is Lua module state (`subscribers` and
# `subscriber_count`, lua/awful/ipc.lua:250-252), destroyed with the Lua state,
# and ipc.broadcast early-returns while subscriber_count is 0
# (lua/awful/ipc.lua:353-357). Every broadcast originates in Lua. So after a
# reload the fd is still open, C still believes it is subscribed, and the client
# simply never hears anything again. Neither side reports an error.
#
# The second half re-subscribes on a fresh connection. If that works while the
# first fails, the defect is the wiped Lua registry and not a dead socket.

. "$(dirname "$0")/lib.sh"

sw_start hr-sub --config "$ROOT_DIR/tests/rc.lua" || finish

SUBOUT=$(sw_sandbox)/events.txt
SUBOUT2=$(sw_sandbox)/events2.txt

# Toggling the selected tag emits property::selected, which broadcasts
# tag_switch (lua/awful/ipc.lua:3513).
TOGGLE='local t = screen.primary.tags[1]; t.selected = false; t.selected = true; return "toggled"'

# Same shape as log_count in lib.sh: grep -c prints 0 and exits 1 on no match,
# so `|| echo 0` would print a second 0 and the comparison below would blow up
# on "0 0".
count_events() {
    local n
    n=$(grep -cF -- 'tag_switch' "$1" 2>/dev/null) || true
    echo "${n:-0}"
}

wait_events() {
    local file="$1" want="$2" deadline=$((SECONDS + 5))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ "$(count_events "$file")" -ge "$want" ] && return 0
        sleep 0.25
    done
    return 1
}

SOMEWM_SOCKET="$(sw_sock hr-sub)" "$SOMEWM_CLIENT" --subscribe tag_switch > "$SUBOUT" 2>&1 &
sub_pid=$!
sw_bg $sub_pid
sleep 1

check_eval hr-sub "phase-1 tag toggle" "$TOGGLE" toggled
if wait_events "$SUBOUT" 1; then
    pass "subscriber receives events before the reload"
else
    fail "subscriber receives events before the reload" "nothing in $SUBOUT"
    finish
fi
before=$(count_events "$SUBOUT")
info "phase-1 events: $before"

sw_reload hr-sub || finish

check "subscriber process is still running" \
    "$(kill -0 $sub_pid 2>/dev/null && echo yes || echo no)" yes

check_eval hr-sub "phase-2 tag toggle" "$TOGGLE" toggled
if wait_events "$SUBOUT" $((before + 1)); then
    pass "the existing subscriber still receives events after the reload"
else
    fail "the existing subscriber still receives events after the reload" \
         "still $(count_events "$SUBOUT") events, fd open and no error reported"
fi

# Isolation half: a fresh subscription proves the transport is fine and the
# Lua-side registry is what was lost.
kill $sub_pid 2>/dev/null || true
SOMEWM_SOCKET="$(sw_sock hr-sub)" "$SOMEWM_CLIENT" --subscribe tag_switch > "$SUBOUT2" 2>&1 &
sub2_pid=$!
sw_bg $sub2_pid
sleep 1

check_eval hr-sub "phase-2 tag toggle for the fresh subscriber" "$TOGGLE" toggled
if wait_events "$SUBOUT2" 1; then
    pass "a freshly subscribed client does receive events (transport is healthy)"
else
    fail "a freshly subscribed client does receive events" \
         "re-subscribing did not help, so the defect is not the Lua registry"
fi

sw_check_log_clean hr-sub "post-reload log"

finish
