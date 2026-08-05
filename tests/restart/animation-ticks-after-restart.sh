#!/usr/bin/env bash
#
# animation_cleanup() removed the keepalive timer, and luaA_state_teardown_lua()
# calls it, so after the first reload arm_keepalive() and disarm_keepalive() were
# no-ops forever. That timer is the only thing that wakes an otherwise idle
# event loop while an animation runs: some_refresh() ticks animations once per
# loop iteration, and the timer is what produces the iterations.
#
# The probe must not touch the instance while the animation runs. Every eval is
# IPC traffic that wakes the loop and drives a refresh, so a poll loop
# (sw_wait_true, check_wait_true) rescues the very animation it is watching and
# passes with the defect present. Arm in one eval, sleep in the shell, read in a
# second.
#
# 2 seconds because animation_tick_all() caps dt at 0.1s: the unfixed path needs
# 20 refreshes between the two evals to finish, far more than two eval round
# trips can drive. The fixed path finishes in 2s of real time.

. "$(dirname "$0")/lib.sh"

ARM='ANIM_DONE = false; awesome.start_animation(2.0, "linear", function() end, function() ANIM_DONE = true end); return "armed"'
DONE='return tostring(ANIM_DONE)'

check_animation_completes() {
    local name="$1" desc="$2"
    if ! sw_eval "$name" "$ARM" || [ "$EVAL_VALUE" != armed ]; then
        fail "$desc" "could not arm the animation: ${EVAL_ERROR:-$EVAL_VALUE}"
        return 1
    fi
    sleep 3
    check_eval "$name" "$desc" "$DONE" true
}

sw_start hr-anim-tick --config "$ROOT_DIR/tests/rc.lua" || finish

check_animation_completes hr-anim-tick "an animation completes on an idle loop"

sw_reload hr-anim-tick || finish

check_animation_completes hr-anim-tick "an animation still completes after the reload"

sw_check_log_clean hr-anim-tick
finish
