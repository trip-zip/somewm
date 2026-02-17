# Investigation: Naughty notification gets stuck and cannot be dismissed

## Related upstream issue: #193

## Problem

Notifications (typically from Firefox/Google Calendar) occasionally remain
stuck on screen and cannot be dismissed by clicking. The "last" notification
in a batch is most commonly affected.

## Two root causes identified

### Root Cause 1: DBus bus isolation (dbus-run-session)

**Status:** Suspected, to be confirmed on affected machine (4070S, weekend test)

When somewm is launched via a display manager using `dbus-run-session`, the
compositor runs on an **isolated DBus session bus**, separate from the systemd
user bus where applications like Firefox operate.

This causes a bus mismatch:

```
Firefox ──notification──→ systemd user bus      (naughty not listening here)

somewm/naughty ──────────→ isolated bus          (Firefox not listening here)
```

Consequences:
- `NotificationClosed` signal from naughty goes to the isolated bus.
  Firefox never receives it and may consider the notification still alive.
- If Firefox sends `CloseNotification` via DBus (e.g. after a timeout),
  it goes to the systemd bus where naughty is not listening. The
  notification remains on screen.
- If another notification daemon exists on the systemd bus, notifications
  may be displayed twice — once by naughty (isolated bus) and once by the
  other daemon. The duplicate cannot be dismissed from within somewm.

**Fix:** Use the systemd user bus directly instead of `dbus-run-session`.
This is already implemented in `somewm-session` and `start-somewm` (via
`somewm-session-install` script). The affected machine (4070S) has not been
updated to this setup yet.

**Relevant code:** `somewm-session` uses
`DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus` instead of
wrapping with `dbus-run-session`.

### Root Cause 2: ipairs + table.remove skips notifications during cleanup

**Status:** Confirmed and reproducible

In `lua/naughty/core.lua:502-506`, the `cleanup()` function removes a
notification from `naughty._active` using `table.remove()` inside an
`ipairs()` loop:

```lua
-- core.lua:502-506
for k, n in ipairs(naughty._active) do
     if n == self then
        table.remove(naughty._active, k)
        naughty.emit_signal("property::active")
     end
end
```

When `table.remove(list, k)` is called, all subsequent elements shift down
by one index. But `ipairs` has already advanced its internal counter, so it
skips the element that slid into position `k`.

Example with 3 notifications [A, B, C]:
1. `k=1`: finds A, removes it → list becomes [B, C]
2. `k=2`: sees C (B slid to index 1, skipped)
3. `k=3`: nil, loop ends
4. **B is never visited**

Additionally, the loop is missing a `break` after the removal, so it
continues iterating with corrupted indices.

**Reproduction (confirmed on both nested and main compositor):**

```bash
# Create 3 persistent notifications
somewm-client eval 'local n = require("naughty"); \
  n.notification({ title="A", message="a", timeout=0 }); \
  n.notification({ title="B", message="b", timeout=0 }); \
  n.notification({ title="C", message="c", timeout=0 }); \
  return #n.active'
# Returns: 3

# Destroy all via ipairs (same pattern as internal code)
somewm-client eval 'local n = require("naughty"); \
  for _,v in ipairs(n.active) do v:destroy() end; \
  return #n.active'
# Returns: 1  ← one notification is stuck!
```

The stuck notification CAN be dismissed by clicking (the click handler
calls `destroy()` individually, which works correctly). But it should
not have survived the batch destruction.

**When this happens in practice:**
- Signal cascade: `property::active` signal (line 505) fires during
  cleanup, triggering listeners that may destroy additional notifications
  in the same event loop cycle
- Transitioning from suspended state: expired notifications are
  batch-processed
- User code or rules that iterate `naughty.active` and destroy matching
  notifications

**Potential fix:** Use reverse iteration or copy the list before iterating:

```lua
-- Option A: iterate in reverse (safe with table.remove)
for k = #naughty._active, 1, -1 do
    if naughty._active[k] == self then
        table.remove(naughty._active, k)
        break  -- only one instance possible
    end
end
naughty.emit_signal("property::active")

-- Option B: add break (minimal fix, since each notification appears once)
for k, n in ipairs(naughty._active) do
    if n == self then
        table.remove(naughty._active, k)
        naughty.emit_signal("property::active")
        break
    end
end
```

## Files involved

| File | Line | Issue |
|------|------|-------|
| `lua/naughty/core.lua` | 502-506 | `ipairs` + `table.remove` without `break` |
| `lua/naughty/core.lua` | 505 | `property::active` signal may cascade |
| `lua/naughty/dbus.lua` | 68-79 | `sendNotificationClosed` depends on correct bus |
| `lua/naughty/layout/box.lua` | 305 | Weak table `__mode="v"` for notification ref |
| `somewm-session` | - | DBus bus configuration (systemd vs isolated) |

## Test plan

1. **DBus isolation (weekend):** Run `somewm-session-install` on 4070S machine,
   switch from display manager to TTY + `somewm-session`. Test if Firefox
   notifications can be dismissed reliably.

2. **ipairs bug:** Already reproducible with the commands above. Fix can be
   validated by running the same reproduction and confirming `#n.active == 0`.
