#!/usr/bin/env bash
#
# A keygrabber must be usable again after reloading during a grab.
#
# globalconf.keygrabber holds a registry ref from the old state and is never
# reset, so the guard at keygrabber.c:128 keeps seeing a live grab and errors
# "keygrabber already running" forever. Stopping it is worse than useless: the
# stop path unrefs an old-state ref against the new registry, which frees an
# unrelated live slot.
#
# The loudest and most user-visible member of the stale-ref cluster.

# xfail: globalconf.keygrabber keeps a stale ref, so a grab held across a reload can never be released

. "$(dirname "$0")/lib.sh"

sw_start hr-kg --config "$ROOT_DIR/tests/rc.lua" || finish

if ! sw_eval hr-kg 'keygrabber.run(function() end); return "grabbed"'; then
    skip "cannot grab the keyboard here: $EVAL_ERROR"
fi
check "a grab can be started before the reload" "$EVAL_VALUE" grabbed

sw_reload hr-kg || finish

# The old grab is gone with the state that owned it, so a fresh grab must be
# accepted. Today the C-side ref outlives it and the guard refuses.
check_eval hr-kg "a new grab can be started after the reload" \
    'local ok, err = pcall(keygrabber.run, function() end); return tostring(ok) .. "|" .. tostring(err)' \
    'true|nil'

finish
