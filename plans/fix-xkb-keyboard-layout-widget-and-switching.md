# Fix: XKB Keyboard Layout Widget & Switching

## Status: FIXED and VERIFIED

Configuration: `us,cz(qwerty)` with compositor-level switching (Alt+Space / wibox click).

## Problem Summary

Two issues with XKB keyboard layout support:

1. **Keyboard layout widget not showing** — the keyboardlayout widget displayed
   nothing because `some_xkb_get_group_names()` returned human-readable names
   that the widget parser couldn't match.

2. **Layout switching reverts on keypress** — switching to Czech via wibox click
   or keybinding appeared to work momentarily (first character was Czech), but
   the layout immediately reverted to US on the next keypress.

## Root Causes

### Bug 1: Widget returns wrong name format

`some_xkb_get_group_names()` used `xkb_keymap_layout_get_name()` which returns
human-readable names like `"English (US)"` and `"Czech (QWERTY)"`. The
AwesomeWM `keyboardlayout` widget expects XKB symbols format with short codes
like `pc+us+cz(qwerty):2` to match against its `xkeyboard_country_code` table.

**Fix:** Rewrote `some_xkb_get_group_names()` to build the symbols string from
RMLVO components stored in `globalconf.keyboard.xkb_layout` and
`globalconf.keyboard.xkb_variant`. Falls back to keymap layout names if no
RMLVO config is available.

### Bug 2: Member keyboards have wrong keymap (layout revert root cause)

`some_rebuild_keyboard_keymap()` called `wlr_keyboard_set_keymap()` only on the
**group virtual keyboard**. Physical member keyboards kept their original
single-layout keymap (e.g. just `us`, with `num_layouts=1`).

When `some_xkb_set_layout_group(1)` tried to set `locked_layout=1` on member
keyboards, XKB silently clamped it to 0 because the member's keymap only had
one layout. This `group=0` then propagated back to the group keyboard via
wlroots' `handle_keyboard_modifiers()`, undoing the switch on the very next
key event.

**Fix:** After setting keymap on the group keyboard, also set it on all member
keyboards so they have the same multi-layout keymap.

### Bug 3: Layout switching used wrong API

The original `some_xkb_set_layout_group()` called `xkb_state_update_mask()`
directly on the group keyboard. This bypassed wlroots' internal modifier
propagation chain. When a key was subsequently pressed, wlroots would
re-serialize modifiers from the member keyboard's xkb_state (which was out of
sync), overwriting the group keyboard's layout back to 0.

**Fix:** Adopted the **Sway pattern** from `sway/commands/input/xkb_switch_layout.c`.
Instead of manipulating xkb_state directly, call `wlr_keyboard_notify_modifiers()`
on each member keyboard. This goes through the proper wlroots path:

```
member xkb_state_update_mask() → keyboard_modifier_update() →
emit modifiers signal → handle_keyboard_modifiers() →
sync all members → propagate to group keyboard →
emit group modifiers signal → somewm keypressmod() → client
```

This is the same code path that XKB's own `grp:alt_shift_toggle` uses internally,
ensuring the member and group xkb_state stay in sync.

## Implementation Details

### `kb_group_device` struct mirror (somewm_api.c)

wlroots' `keyboard_group_device` struct is private (defined in
`types/wlr_keyboard_group.c:15-23`). To iterate member keyboards, we mirror
the struct definition. Verified to match wlroots 0.19 exactly.

### `some_xkb_set_layout_group()` — Sway pattern (somewm_api.c)

```c
// Iterate member keyboards and notify each one
struct kb_group_device *dev;
wl_list_for_each(dev, &kb_group->wlr_group->devices, link) {
    struct wlr_keyboard *member = dev->keyboard;
    if (member->xkb_state) {
        wlr_keyboard_notify_modifiers(member,
            xkb_state_serialize_mods(member->xkb_state, XKB_STATE_MODS_DEPRESSED),
            xkb_state_serialize_mods(member->xkb_state, XKB_STATE_MODS_LATCHED),
            xkb_state_serialize_mods(member->xkb_state, XKB_STATE_MODS_LOCKED),
            group);
    }
}
```

Reference: Sway's `switch_layout()` in `sway/commands/input/xkb_switch_layout.c`
calls `wlr_keyboard_notify_modifiers()` on each physical keyboard with the new
group index while preserving existing modifier state.

### `some_rebuild_keyboard_keymap()` — member keymap sync (somewm_api.c)

```c
wlr_keyboard_set_keymap(&kb_group->wlr_group->keyboard, keymap);

// Sync keymap to member keyboards
struct kb_group_device *dev;
wl_list_for_each(dev, &kb_group->wlr_group->devices, link) {
    if (dev->keyboard->keymap != keymap)
        wlr_keyboard_set_keymap(dev->keyboard, keymap);
}
```

### `some_xkb_get_group_names()` — RMLVO short codes (somewm_api.c)

Builds symbols string from `globalconf.keyboard.xkb_layout` and
`globalconf.keyboard.xkb_variant` instead of `xkb_keymap_layout_get_name()`.

Output example: `pc+us+cz(qwerty):2`

## wlroots Key Event Flow Reference

```
Physical key press on member keyboard
  → wlr_keyboard_notify_key(member) [wlr_keyboard.c:100]:
    1. keyboard_key_update(member)
    2. emit key signal → handle_keyboard_key [wlr_keyboard_group.c]:
       → wlr_keyboard_notify_key(group_keyboard):
         a. emit key signal → somewm keypress()
         b. xkb_state_update_key(group->xkb_state)
         c. keyboard_modifier_update(group)
    3. xkb_state_update_key(member->xkb_state)
    4. keyboard_modifier_update(member) → if changed: emit modifiers
       → handle_keyboard_modifiers [wlr_keyboard_group.c:116]
       → sync all members → propagate to group keyboard
       → somewm keypressmod() → client
```

### handle_keyboard_modifiers (wlr_keyboard_group.c:116)

When a member's modifiers change:
1. Read the triggering member's modifiers
2. Sync to all other members that differ (recursive)
3. Once all members match → propagate to group keyboard
4. Group keyboard emits modifiers signal → keypressmod() → client

## Note on grp:alt_shift_toggle

The XKB option `grp:alt_shift_toggle` compiles a layout toggle mechanism
into the keymap itself. This works alongside compositor-level switching
(both use `wlr_keyboard_notify_modifiers` internally). However, using both
simultaneously means two independent toggle mechanisms exist, which can
cause confusing double-toggle behavior. Recommended to use one or the other.

## Files Modified

| File | Function | Change |
|------|----------|--------|
| `somewm_api.c` | `kb_group_device` struct | Mirror of wlroots private struct for member iteration |
| `somewm_api.c` | `some_xkb_set_layout_group()` | Rewritten to Sway pattern (notify members) |
| `somewm_api.c` | `some_xkb_get_group_names()` | RMLVO short codes instead of human-readable names |
| `somewm_api.c` | `some_rebuild_keyboard_keymap()` | Sync keymap to member keyboards |
